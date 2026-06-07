"""CloakBrowser automation for the personal PayPal web UI (paypal.com).

This is the productionized version of gate/paypal_cloak.py. We drive PayPal's own
web UI in a real stealth Chromium and DOM-scrape the activity list the page
server-renders — we never replay raw XHRs (the device fingerprint + session only
exist inside a real browser). The persistent profile (PROFILE_DIR) is the warmed
device, so it must live on a durable rw volume (see config.PROFILE_DIR).

Manual sync only: a normal login surfaces PayPal's device step-up
("Bestätigen Sie Ihre Identität" -> PayPal-App push), approved out-of-band on the
user's phone. We block-and-poll inside the ONE /sync request until approval (the
user is present), bounded by PUSH_DEADLINE_S. There is nothing to TYPE (unlike
easybank's mTAN), so there is no paused-context registry here.

Error taxonomy mirrors the easybank sidecar (easybank-scraper/app/easybank.py);
main.py maps each class to the HTTP status the Rails Paypal::ScraperClient expects:
  PushTimeout    -> 409 (device push not approved within PUSH_DEADLINE_S)
  LoginFailed    -> 422 (wrong username/password)
  CaptchaBlocked -> 422 (a reCAPTCHA/security check appeared; non-retryable)
  TransientError -> 503 (timeout, navigation, browser/network fault — retry)

Never log credentials, balances, card numbers or counterparties. Only ever log
structural facts (which step, how many rows, whether we truncated).
"""

from __future__ import annotations

import logging
import os
import time
from datetime import date, timedelta

try:
    from cloakbrowser import launch_persistent_context
except ImportError:  # pragma: no cover - real image always has it; tests don't import this module
    launch_persistent_context = None  # type: ignore[assignment]

from . import config, normalize

log = logging.getLogger("paypal-scraper")

BASE = "https://www.paypal.com"


# --- error taxonomy: each maps to a distinct HTTP status in main.py ----------
class ScraperError(Exception):
    """Base class. ``message`` is safe to surface and never contains secrets."""

    def __init__(self, message: str):
        super().__init__(message)
        self.message = message


class LoginFailed(ScraperError):
    """User-actionable: PayPal rejected the username/password."""


class CaptchaBlocked(ScraperError):
    """A reCAPTCHA / "Sicherheitsüberprüfung" appeared. NON-retryable: the UI
    tells the user to try again later (we do not solve captchas)."""


class PushTimeout(ScraperError):
    """The device-app push step-up was not approved within PUSH_DEADLINE_S."""


class TransientError(ScraperError):
    """Timeout, navigation failure, browser crash or network fault — retry."""


# The persistent-profile SingletonLock CloakBrowser/Chromium writes. If a previous
# /sync was hard-aborted (e.g. main.py's SYNC_DEADLINE_S fired and the worker
# thread was abandoned), this file can be left behind and the NEXT launch dies
# with Chromium exit-21. We clear a STALE lock before launching.
_SINGLETON_LOCKS = ("SingletonLock", "SingletonCookie", "SingletonSocket")

# The context currently held by the worker thread, so a /sync that main.py times
# out can force-close it (else the abandoned worker keeps the SingletonLock and
# the next launch hits exit-21). Set under _launch, cleared on close.
_active_ctx = None


def _clear_stale_singleton_locks() -> None:
    for name in _SINGLETON_LOCKS:
        path = os.path.join(config.PROFILE_DIR, name)
        try:
            if os.path.lexists(path):
                os.remove(path)
                log.warning("removed stale profile lock %s before launch", name)
        except OSError:
            pass


def _launch():
    """Open the persistent context (the warmed device profile) with a PINNED
    fingerprint and (default) human-like interaction, returning (ctx, page).

    CloakBrowser randomizes --fingerprint per launch, which would make every
    sync look like a new device and re-trip PayPal's push step-up; we disable the
    default stealth args and pass a fixed --fingerprint seed so PayPal sees ONE
    stable device. humanize is a launch kwarg (human mouse curves + typing
    delays), the primary captcha-avoidance lever.

    A stale SingletonLock from a hard-aborted previous /sync is cleaned and the
    launch retried ONCE so a single timed-out sync doesn't wedge the sidecar."""
    global _active_ctx
    if launch_persistent_context is None:
        raise TransientError("Browser engine is unavailable in this image.")

    kwargs: dict = {
        "headless": config.HEADLESS,
        "stealth_args": False,
        "args": [
            "--no-sandbox",
            f"--fingerprint={config.PP_FINGERPRINT}",
            "--fingerprint-platform=windows",
        ],
        "humanize": config.HUMANIZE,
    }
    if config.PROXY_URL:
        kwargs["proxy"] = {"server": config.PROXY_URL}

    try:
        ctx = launch_persistent_context(config.PROFILE_DIR, **kwargs)
    except Exception:
        # Most likely a stale SingletonLock from a previously-aborted sync. Clear
        # it and retry once; a second failure surfaces as a transient.
        _clear_stale_singleton_locks()
        ctx = launch_persistent_context(config.PROFILE_DIR, **kwargs)

    _active_ctx = ctx
    page = ctx.pages[0] if ctx.pages else ctx.new_page()
    page.set_default_timeout(config.ACTION_TIMEOUT_MS)
    return ctx, page


def _close_quietly(ctx) -> None:
    global _active_ctx
    try:
        ctx.close()
    except Exception:
        pass
    if ctx is _active_ctx:
        _active_ctx = None


def force_close_active() -> None:
    """Force-close the context held by an abandoned worker thread (called by
    main.py when asyncio.wait_for cuts a /sync). Releases the persistent-profile
    SingletonLock so the next launch doesn't hit Chromium exit-21."""
    ctx = _active_ctx
    if ctx is not None:
        _close_quietly(ctx)


def _click(page, locator) -> None:
    """Move the (humanized) mouse to the element before clicking, never a bare
    .click() — robotic instant clicks were part of what scored the spike as a bot
    (§10.5). hover() drives the human-curve mouse move; click() then fires."""
    try:
        locator.hover(timeout=config.ACTION_TIMEOUT_MS)
    except Exception:
        pass
    locator.click(timeout=config.ACTION_TIMEOUT_MS)


def _is_captcha(page) -> bool:
    """Detect a reCAPTCHA / security-check interstitial we can't solve. Cheap
    yes/no; we never try to solve it.

    CAREFUL: reCAPTCHA always injects an INVISIBLE badge iframe (the score-based
    v3/Enterprise widget) on a normal PayPal login, so a bare
    `iframe[src*='recaptcha']` match would misclassify EVERY login as
    captcha_blocked (non-retryable) — including a perfectly fine device step-up.
    We only count a captcha when there is a VISIBLE interactive challenge: the
    api2/anchor iframe rendered visible, or the explicit security-check copy."""
    for needle in ("Sicherheitsüberprüfung", "Security Challenge", "Ich bin kein Roboter"):
        try:
            if page.get_by_text(needle, exact=False).count() > 0:
                return True
        except Exception:
            continue
    try:
        anchor = page.locator("iframe[src*='recaptcha/api2/anchor']")
        if anchor.count() > 0 and anchor.first.is_visible():
            return True
    except Exception:
        pass
    return False


# --- login -------------------------------------------------------------------
def _fill_login(page, username: str, password: str) -> None:
    """Open /signin and submit credentials. PayPal may show a 2-step form
    (#email -> #btnNext -> #password) or a single form (#email + #password
    together). Humanized fills + mouse-to-button clicks. Never logs the values."""
    page.goto(BASE + "/signin", wait_until="domcontentloaded", timeout=config.NAV_TIMEOUT_MS)

    email = page.locator("#email")
    email.first.fill(username, timeout=config.ACTION_TIMEOUT_MS)

    # 2-step layout: a "Weiter"/Next button advances to the password screen.
    next_btn = page.locator("#btnNext")
    if next_btn.count() and next_btn.first.is_visible():
        _click(page, next_btn.first)
        page.wait_for_timeout(800)

    page.locator("#password").first.fill(password, timeout=config.ACTION_TIMEOUT_MS)
    _click(page, page.locator("#btnLogin").first)


def _await_login_outcome(page, deadline_s: float) -> str:
    """Poll until login settles into one of: 'dashboard' (/myaccount reached),
    'stepup' (/authflow device challenge), 'captcha' (security check), or
    'timeout'. Pump via page.wait_for_timeout, NEVER time.sleep (CloakBrowser
    dispatches buffered events only during a Playwright call, §10.6)."""
    end = time.monotonic() + deadline_s
    while time.monotonic() < end:
        url = page.url
        if "/myaccount" in url:
            return "dashboard"
        # Check the step-up branch BEFORE captcha: the /authflow device step-up is
        # the normal, retryable path; the (invisible) reCAPTCHA badge co-exists on
        # it, so testing captcha first would mislabel a fine step-up as blocked.
        if "/authflow" in url:
            return "stepup"
        if _is_captcha(page):
            return "captcha"
        page.wait_for_timeout(500)
    # Final read after the window.
    if "/myaccount" in page.url:
        return "dashboard"
    if "/authflow" in page.url:
        return "stepup"
    if _is_captcha(page):
        return "captcha"
    return "timeout"


def _approve_via_push(page, push_deadline: float | None = None) -> None:
    """Drive the device step-up: pick the PayPal-app option, click Weiter (fires
    the phone push), then BLOCK inside this one request polling page.url for
    /myaccount until the user approves on their phone.

    ``push_deadline`` is an absolute ``time.monotonic()`` instant: the push wait
    is bounded by min(PUSH_DEADLINE_S, remaining /sync budget) so it is NON-
    additive to the login navigation — a slow-but-legit approval raises
    PushTimeout (409) here rather than letting main.py's SYNC_DEADLINE_S cut the
    whole call as a transient (503) and skip the circuit breaker. Pump ONLY via
    page.wait_for_timeout (§10.6)."""
    # Select "Verwenden Sie die PayPal-App" then "Weiter". Best-effort: if the
    # app option is already the default, the Weiter click alone fires the push.
    try:
        app_option = page.get_by_text("Verwenden Sie die PayPal-App", exact=False)
        if app_option.count():
            _click(page, app_option.first)
            page.wait_for_timeout(500)
    except Exception:
        pass
    try:
        weiter = page.get_by_role("button", name="Weiter")
        if weiter.count() == 0:
            weiter = page.get_by_text("Weiter", exact=False)
        if weiter.count():
            _click(page, weiter.first)
    except Exception:
        pass

    log.info("step-up: device push fired; waiting for phone approval")
    end = time.monotonic() + config.PUSH_DEADLINE_S
    if push_deadline is not None:
        end = min(end, push_deadline)
    while time.monotonic() < end:
        if "/myaccount" in page.url:
            log.info("step-up: approved; reached the dashboard")
            return
        if _is_captcha(page):
            raise CaptchaBlocked(
                "PayPal showed a security check during the device approval."
            )
        page.wait_for_timeout(1000)
    raise PushTimeout(
        "The PayPal app notification was not approved in time. Try the sync again."
    )


def login(page, username: str, password: str, push_deadline: float | None = None) -> None:
    """Log in and land on /myaccount. Raises a typed error otherwise. Does NOT
    own the browser lifecycle (the caller in sync() does).

    ``push_deadline`` (absolute time.monotonic()) bounds the device-push wait so
    it never runs additively past the /sync budget (see _approve_via_push)."""
    _fill_login(page, username, password)
    outcome = _await_login_outcome(page, config.NAV_TIMEOUT_MS / 1000)
    if outcome == "dashboard":
        return
    if outcome == "stepup":
        _approve_via_push(page, push_deadline=push_deadline)
        return
    if outcome == "captcha":
        raise CaptchaBlocked(
            "PayPal couldn't sync automatically — a security check appeared. "
            "Try again later."
        )
    # No dashboard, no step-up, no captcha within the window => bad credentials is
    # the overwhelmingly likely cause (PayPal re-renders the signin form).
    raise LoginFailed("PayPal rejected the username or password.")


# --- scrape ------------------------------------------------------------------
def _row_id(handle) -> str:
    """Stable 17-char Transaktionscode from a row element: the
    js_transactionItem-<txid> class (fallback aria-controls=
    transactionDetails-<txid>). Returns '' if neither is present (normalize then
    synthesizes a deterministic id). NO per-row expand, NO inline XHR (§10)."""
    try:
        cls = handle.get_attribute("class") or ""
        for token in cls.split():
            if token.startswith("js_transactionItem-"):
                return token[len("js_transactionItem-"):]
    except Exception:
        pass
    try:
        controls = handle.get_attribute("aria-controls") or ""
        if controls.startswith("transactionDetails-"):
            return controls[len("transactionDetails-"):]
    except Exception:
        pass
    return ""


def _text_of(scope, testid: str) -> str:
    """inner_text of the first [data-testid=...] within a scope element, or ''."""
    try:
        loc = scope.locator(f"[data-testid='{testid}']").first
        if loc.count():
            return (loc.inner_text(timeout=config.ACTION_TIMEOUT_MS) or "").strip()
    except Exception:
        pass
    return ""


# A row OR a section/month header, matched together so we can walk them in
# DOCUMENT ORDER. The header is what carries the year for the rows beneath it
# ("Mai 2026"); status/relative headers ("Abgeschlossen", "Diese Woche") carry no
# year — normalize's year-carry walk skips those. Emitting the headers interleaved
# (newest-first, same as the rows) is what lets normalize resolve the year for any
# window wider than the current month (§10.2). Without it the year-carry never runs.
_ROW_SELECTOR = "[class*='js_transactionItem-']"
_HEADER_SELECTOR = "[data-testid='activity_list_header_view'], [class*='listBucketHeader']"
_ROW_OR_HEADER = f"{_ROW_SELECTOR}, {_HEADER_SELECTOR}"


def _is_header(handle) -> bool:
    """True if a combined-walk element is a section/month header (not a tx row).
    A tx row carries the js_transactionItem- class; a header does not."""
    try:
        cls = handle.get_attribute("class") or ""
    except Exception:
        cls = ""
    return "js_transactionItem-" not in cls


def _scrape_rows(page) -> list[dict]:
    """DOM-scrape every transaction row ONCE — no expand — INTERLEAVED with the
    section/month headers in document order. Each tx row is a
    `js_transactionItem-<txid>` element (id on the OUTER class, data on the inner
    test-ids); each header is emitted as a ``{"header": <text>}`` marker that
    normalize's single-pass year-carry consumes (§10.2). We walk a COMBINED
    locator so rows and headers stay in their true newest-first order."""
    rows: list[dict] = []
    nodes = page.locator(_ROW_OR_HEADER)
    count = nodes.count()
    for i in range(count):
        node = nodes.nth(i)
        if _is_header(node):
            try:
                text = (node.inner_text(timeout=config.ACTION_TIMEOUT_MS) or "").strip()
            except Exception:
                text = ""
            rows.append({"header": text})
            continue
        rows.append(
            {
                "id": _row_id(node),
                "merchant": _text_of(node, "counterparty_name"),
                "amount_text": _text_of(node, "transaction_amount"),
                "description_text": _text_of(node, "transaction_description"),
                "notes": _text_of(node, "transaction-notes"),
            }
        )
    return rows


def _find_more_button(page):
    """The 'Mehr' (show-more) pagination control, only if visible AND enabled (a
    disabled-but-visible button is the end-of-history state). Matches the
    `show_more` test-id, falling back to the German label by button role."""
    candidates = [
        page.locator("[data-testid='show_more']"),
        page.locator("#show_more"),
        page.get_by_role("button", name="Mehr"),
    ]
    for loc in candidates:
        try:
            if loc.count() and loc.first.is_visible() and loc.first.is_enabled():
                return loc.first
        except Exception:
            continue
    return None


def _paginate(page) -> bool:
    """PayPal's activity list is INFINITE-SCROLL — there is NO 'Mehr' button. Scroll
    to the bottom repeatedly to lazy-load older rows until the row count stops
    growing (the end of the date window) or we hit PAGE_CAP. Returns True if
    PAGE_CAP was hit (possible truncation -> the caller fails loud)."""
    rows_sel = "[class*='js_transactionItem-']"
    last = page.locator(rows_sel).count()
    for _ in range(config.PAGE_CAP):
        try:
            page.keyboard.press("End")        # jump focus to page bottom
            page.mouse.wheel(0, 120000)        # and scroll -> triggers the lazy-load
        except Exception:
            return False
        # Wait for the next chunk to lazy-load (a slow box can take a while); pump
        # the event loop via wait_for_timeout, never time.sleep (§10.6).
        end = time.monotonic() + (config.NAV_TIMEOUT_MS / 1000)
        while time.monotonic() < end and page.locator(rows_sel).count() == last:
            page.wait_for_timeout(400)
        now = page.locator(rows_sel).count()
        log.info("paginate: %d rows loaded", now)
        if now == last:
            return False  # no growth after a long wait -> reached the end of history
        last = now
    log.warning("pagination hit PAGE_CAP=%s; activity may be truncated", config.PAGE_CAP)
    return True


# The legitimate "no activity in this window" empty state. ONLY a present
# empty-state element makes a 0-row scrape a valid result; otherwise a 0-row
# scrape means the DOM contract broke (e.g. js_transactionItem- was renamed) and
# we must fail loud rather than silently ingest nothing (§10 / [R:H2]).
_EMPTY_STATE_SELECTOR = (
    "[data-testid='activity_empty_state'], [data-testid='no_activity'], "
    "[class*='emptyState'], [class*='noResults']"
)


def _has_empty_state(page) -> bool:
    try:
        return page.locator(_EMPTY_STATE_SELECTOR).count() > 0
    except Exception:
        return False


def scrape(page, date_from: str, date_to: str) -> list[dict]:
    """Navigate to the activity list for [date_from, date_to], DOM-scrape every
    row once, paginate within PAGE_CAP, and return normalized wire records.

    Fail-loud: if PAGE_CAP is hit (possible truncation), or the list settled with
    NO transaction row AND NO empty-state marker (the DOM contract broke), or a
    row can't be normalized, raise TransientError — never return a partial or a
    spurious 0-row result as success [R: H2]."""
    page.goto(
        f"{BASE}/myaccount/activities?start_date={date_from}&end_date={date_to}",
        wait_until="domcontentloaded",
        timeout=config.NAV_TIMEOUT_MS,
    )
    # Let the server-rendered list settle. Break early once rows OR a legitimate
    # empty-state marker appear, so a genuinely empty window doesn't spin the full
    # NAV_TIMEOUT_MS budget.
    end = time.monotonic() + (config.NAV_TIMEOUT_MS / 1000)
    while time.monotonic() < end:
        if _is_captcha(page):
            raise CaptchaBlocked("PayPal showed a security check on the activity list.")
        if page.locator(_ROW_SELECTOR).count() > 0 or _has_empty_state(page):
            break
        page.wait_for_timeout(500)

    truncated = _paginate(page)
    raw = _scrape_rows(page)
    if truncated:
        raise TransientError(
            "Activity pagination hit the page cap; refusing to ingest a possibly "
            "truncated history."
        )

    # A 0-row scrape is only legitimate when an empty-state marker is present. No
    # row AND no empty state => the DOM contract broke; fail loud (retryable).
    has_tx_row = any("header" not in r for r in raw)
    if not has_tx_row and not _has_empty_state(page):
        raise TransientError(
            "Activity list rendered no transaction rows and no empty-state marker; "
            "the page contract may have changed. Refusing to ingest an empty result."
        )
    try:
        return normalize.normalize(raw, date_from, date_to)
    except ValueError as e:
        # A row we could not parse (amount/date) is a fail-loud condition: better
        # a clean retryable error than silently dropping or mis-booking a row.
        raise TransientError(f"Failed to normalize a scraped row: {e}") from e


# --- balance (best-effort, non-critical) -------------------------------------
# The dashboard (/myaccount/summary) carries a "PayPal-Guthaben" card with the
# available balance ("0,00 €" / "Verfügbar"). We read it text-anchored, NOT via a
# brittle deep CSS path, so a layout reshuffle that keeps the heading still works.
_BALANCE_HEADING = "PayPal-Guthaben"


def read_balance(page) -> dict | None:
    """Best-effort scrape of the "PayPal-Guthaben" card on the post-login
    dashboard. Returns {"amount", "currency"} (e.g. {"amount":"0.00",
    "currency":"EUR"}) or None.

    Resilient + NON-fatal: ANY failure (card absent, no amount, locator/timeout)
    returns None and is swallowed at debug level — the balance is non-critical and
    must NEVER raise or fail the transaction sync. Must be called while still on
    /myaccount, BEFORE scrape() navigates to the activity list.

    Strategy: anchor on the heading text, climb to an enclosing container, read its
    inner_text, and let normalize.parse_balance regex the first currency amount out
    (reusing the activity-amount parsing). Never logs the balance value."""
    try:
        # Exact hook (verified from the real dashboard DOM): the available-balance
        # amount sits in data-test-id="available-balance" (e.g. "0,00 €"), inside the
        # data-test-id="balance" card. Prefer it; fall back to the heading-anchored
        # ancestor walk if PayPal ever restructures the card.
        try:
            amount_el = page.locator("[data-test-id='available-balance']")
            if amount_el.count():
                text = (amount_el.first.inner_text(timeout=config.ACTION_TIMEOUT_MS) or "").strip()
                balance = normalize.parse_balance(text)
                if balance is not None:
                    log.debug("balance: read available-balance")
                    return balance
        except Exception:
            pass

        anchor = page.get_by_text(_BALANCE_HEADING, exact=False)
        if not anchor.count():
            log.debug("balance: PayPal-Guthaben card not found")
            return None
        node = anchor.first
        # Walk up a few ancestors so the amount + "Verfügbar" that sit beside the
        # heading are inside the scope we read (the heading element alone is just
        # the label). xpath ancestor levels, widening until an amount parses.
        for xpath in ("xpath=.", "xpath=..", "xpath=../..", "xpath=../../.."):
            try:
                scope = node.locator(xpath)
                text = (scope.inner_text(timeout=config.ACTION_TIMEOUT_MS) or "").strip()
            except Exception:
                continue
            balance = normalize.parse_balance(text)
            if balance is not None:
                log.debug("balance: read PayPal-Guthaben card")
                return balance
        log.debug("balance: PayPal-Guthaben card had no parseable amount")
        return None
    except Exception:
        log.debug("balance: read failed; skipping (non-critical)", exc_info=True)
        return None


# --- public surface (called from main.py via asyncio.to_thread) --------------
def sync(username: str, password: str, date_from: str | None = None,
         date_to: str | None = None) -> dict:
    """One blocking call: log in (handling the device push), then scrape the
    activity for the window. Defaults to the last 30 days. Owns the browser
    lifecycle: a fresh persistent context per request (no warm in-memory ctx;
    continuity comes from the on-disk profile)."""
    today = date.today()
    date_to = date_to or today.isoformat()
    date_from = date_from or (today - timedelta(days=30)).isoformat()

    # Absolute push deadline: cap the device-push wait at min(PUSH_DEADLINE_S,
    # remaining /sync budget minus a scrape reserve), so a slow approval raises
    # PushTimeout (409) inside login() instead of being cut by main.py's
    # SYNC_DEADLINE_S as a transient (503). Non-additive to the login navigation.
    push_deadline = time.monotonic() + max(
        0.0, config.SYNC_DEADLINE_S - config.SCRAPE_RESERVE_S
    )

    ctx = None
    try:
        ctx, page = _launch()
        login(page, username, password, push_deadline=push_deadline)
        # Read the dashboard balance while still on /myaccount, BEFORE scrape()
        # navigates to the activity list. Best-effort + non-fatal (returns None on
        # any failure) so a missing/changed Guthaben card never fails the sync.
        balance = read_balance(page)
        transactions = scrape(page, date_from, date_to)
        _close_quietly(ctx)
        return {
            "transactions": transactions,
            "balance": balance,
            "date_from": date_from,
            "date_to": date_to,
        }
    except ScraperError:
        _close_quietly(ctx)
        raise
    except Exception as e:  # noqa: BLE001 - any browser/network fault is transient
        _close_quietly(ctx)
        raise TransientError("Sync failed due to a browser or network error.") from e
