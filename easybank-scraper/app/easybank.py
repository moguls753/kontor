"""CloakBrowser automation for banking.easybank.de (VeriChannel / Angular).

This is the hardened, productionized version of gate/easybank_cloak.py. We drive
the bank's OWN Angular UI in a real stealth Chromium and CAPTURE the JSON it
fetches (RetailLanding + AccountTransactionHistory) — we never replay raw POSTs,
because the device fingerprint + trusted-device cookie only exist inside a real
browser session. The persistent profile (PROFILE_DIR) is that trusted device, so
it must live on a durable rw volume (see config.PROFILE_DIR).

Error taxonomy mirrors the TR sidecar (scraper/app/tr_api.py); main.py maps each
class to the HTTP status the Phase-2 Rails EasyBank::ScraperClient expects:
  MtanRequired   -> 409 (login needs an mTAN; resume via /mtan)
  SessionExpired -> 409 (a resumed/paused context is gone)
  MtanFailed     -> 422 (wrong/expired mTAN code)
  LoginFailed    -> 422 (wrong username/password)
  TransientError -> 503 (timeout, navigation, browser/network fault — retry)

Never log credentials, the mTAN code, card numbers or balances. Only ever log
structural facts (which step, which capture arrived, whether we truncated).
"""

from __future__ import annotations

import logging
import re
import threading
import time
import uuid

try:
    from cloakbrowser import launch_persistent_context
except ImportError:  # pragma: no cover - real image always has it; tests don't import this module
    launch_persistent_context = None  # type: ignore[assignment]

from . import config, normalize

log = logging.getLogger("easybank-scraper")

BASE = "https://banking.easybank.de"


# --- error taxonomy: each maps to a distinct HTTP status in main.py ----------
class ScraperError(Exception):
    """Base class. ``message`` is safe to surface and never contains secrets."""

    def __init__(self, message: str):
        super().__init__(message)
        self.message = message


class MtanRequired(ScraperError):
    """The bank demanded an mTAN. The browser context is paused and held so the
    user can submit the code via /mtan. NOT an error in the failure sense — main
    surfaces it as a structured 409 with the masked phone/reference."""

    def __init__(self, message: str, *, pairing_id: str, masked_phone: str | None,
                 reference: str | None, expires_in: int):
        super().__init__(message)
        self.pairing_id = pairing_id
        self.masked_phone = masked_phone
        self.reference = reference
        self.expires_in = expires_in


class SessionExpired(ScraperError):
    """A paused, mTAN-pending context is unknown — sidecar restart or TTL
    elapsed. The user must start the login again."""


class MtanFailed(ScraperError):
    """User-actionable: the submitted mTAN code was wrong or expired."""


class LoginFailed(ScraperError):
    """User-actionable: the bank rejected the username/password."""


class TransientError(ScraperError):
    """Timeout, navigation failure, browser crash or network fault — retry."""


# --- captured-response holder ------------------------------------------------
class _Capture:
    """Accumulates the JSON the Angular app fetches. RetailLanding overwrites
    (one dashboard); history accumulates so paginated "Weitere Umsätze" pages
    are all retained for normalization."""

    __slots__ = ("landing", "history_pages")

    def __init__(self) -> None:
        self.landing: dict | None = None
        self.history_pages: list[dict] = []

    def attach(self, page) -> None:
        def on_response(resp) -> None:
            url = resp.url
            try:
                if "/services/flow/RetailLanding" in url:
                    self.landing = resp.json()
                elif "/services/flow/AccountTransactionHistory" in url:
                    self.history_pages.append(resp.json())
            except Exception:
                # A non-JSON or partially-read body is just a miss; never let a
                # capture callback raise into Playwright's event loop.
                pass

        page.on("response", on_response)


# --- paused-login registry (login -> mtan), with TTL + leak-proof cleanup ----
class _Pending:
    """A live, mTAN-pending CloakBrowser context held between /login and /mtan.
    Owns the context so cleanup is a single close()."""

    __slots__ = ("ctx", "page", "capture", "created", "backfill_days")

    def __init__(self, ctx, page, capture: _Capture, backfill_days: int) -> None:
        self.ctx = ctx
        self.page = page
        self.capture = capture
        self.created = time.monotonic()
        self.backfill_days = backfill_days


# Guarded by a plain Lock: every browser call runs in a worker thread (main.py
# uses asyncio.to_thread), so this is cross-thread, not cross-coroutine, state.
_pending: dict[str, _Pending] = {}
_pending_lock = threading.Lock()


def _close_quietly(ctx) -> None:
    try:
        ctx.close()
    except Exception:
        pass


def _evict_expired() -> None:
    """Close and drop any paused context older than the TTL so neither Chromium
    processes nor the registry can leak when a user abandons an mTAN."""
    now = time.monotonic()
    with _pending_lock:
        stale = [pid for pid, p in _pending.items() if now - p.created > config.MTAN_TTL_S]
        victims = [_pending.pop(pid) for pid in stale]
    for p in victims:
        _close_quietly(p.ctx)


def _store_pending(p: _Pending) -> str:
    _evict_expired()
    pairing_id = uuid.uuid4().hex
    # Hard cap so a burst of /login calls can't pile up live Chromium contexts
    # (each paused login holds a browser). Over the cap, evict the oldest and
    # close it outside the lock.
    victim = None
    with _pending_lock:
        if len(_pending) >= config.MAX_PENDING:
            oldest = min(_pending, key=lambda pid: _pending[pid].created)
            victim = _pending.pop(oldest)
        _pending[pairing_id] = p
    if victim is not None:
        _close_quietly(victim.ctx)
    return pairing_id


def _take_pending(pairing_id: str) -> _Pending:
    """Pop a paused context for resumption. Popped (not peeked) so a parallel
    /mtan can't double-drive the same browser; on failure we re-store it."""
    _evict_expired()
    with _pending_lock:
        p = _pending.pop(pairing_id, None)
    if p is None:
        raise SessionExpired("Login session expired. Start the login again.")
    return p


# --- low-level browser plumbing ----------------------------------------------
def _launch():
    """Open the persistent context (the trusted-device profile) and return
    (ctx, page) with response capture already attached. Honours the egress proxy
    and headless flag from config."""
    if launch_persistent_context is None:
        raise TransientError("Browser engine is unavailable in this image.")

    kwargs: dict = {"headless": config.HEADLESS}
    if config.PROXY_URL:
        # Route the browser's traffic through the egress proxy so the squid
        # CONNECT allowlist is its only path off the box.
        kwargs["proxy"] = {"server": config.PROXY_URL}

    ctx = launch_persistent_context(config.PROFILE_DIR, **kwargs)
    page = ctx.pages[0] if ctx.pages else ctx.new_page()
    page.set_default_timeout(config.ACTION_TIMEOUT_MS)
    return ctx, page


def _looks_like_mtan(page) -> bool:
    """Detect the bank's mTAN modal by its German copy. Cheap and resilient to
    DOM-class churn; we only need a yes/no before deciding to pause."""
    for needle in ("mTAN", "per SMS", "SMS-Code", "Sicherheitscode"):
        try:
            if page.get_by_text(needle, exact=False).count() > 0:
                return True
        except Exception:
            continue
    return False


def _mtan_hint(page) -> tuple[str | None, str | None]:
    """Best-effort (masked_phone, reference) scraped from the mTAN modal for the
    UI. Both optional — never block on them, never log them.

    The bank masks the recipient itself, e.g. "**********5836" (masking chars +
    the last digits) — NOT a "+49…" number; the only "+49" strings in the modal
    are the customer-service hotlines, so we must NOT grab those. We match the
    masking pattern instead, plus the "Referenz" code (e.g. "Referenz: 6W0SH1")."""
    masked = None
    reference = None
    try:
        body = page.locator("body").inner_text(timeout=2000) or ""
        m = re.search(r"[*•xX#]{3,}\s*\d{2,6}", body)
        if m:
            masked = m.group(0).strip()
        ref = re.search(r"Referenz[:\s]*([A-Z0-9]{4,})", body)
        if ref:
            reference = ref.group(1).strip()
    except Exception:
        pass
    return masked, reference


def _fill_login(page, username: str, password: str) -> None:
    """Open /Login and submit credentials, with label->type->role fallbacks so a
    minor Angular relabel doesn't break us. Never logs the values."""
    page.goto(BASE + "/Login", wait_until="domcontentloaded", timeout=config.NAV_TIMEOUT_MS)

    user_field = page.get_by_label("Benutzername")
    if user_field.count() == 0:
        user_field = page.locator("input[type='text'], input:not([type])").first
    user_field.fill(username, timeout=config.ACTION_TIMEOUT_MS)

    pw_field = page.get_by_label("Passwort")
    if pw_field.count() == 0:
        pw_field = page.locator("input[type='password']").first
    pw_field.fill(password, timeout=config.ACTION_TIMEOUT_MS)

    submit = page.get_by_role("button", name="Anmelden")
    if submit.count() == 0:
        submit = page.get_by_text("Anmelden", exact=False).first
    submit.click(timeout=config.ACTION_TIMEOUT_MS)


def _await_login_outcome(page, capture: _Capture, deadline_s: float) -> str:
    """Poll until the dashboard's RetailLanding JSON is captured ("landing"), the
    mTAN modal appears ("mtan"), or we time out ("timeout").

    Crucially this pumps the browser via page.wait_for_timeout, NOT time.sleep:
    CloakBrowser's sync Playwright API only dispatches buffered response events
    while a Playwright call is running, so a plain sleep would never let `capture`
    observe the RetailLanding response — that bug made every login time out and
    fall through to LoginFailed even though the dashboard had actually loaded."""
    end = time.monotonic() + deadline_s
    while time.monotonic() < end:
        if capture.landing is not None:
            return "landing"
        if _looks_like_mtan(page):
            return "mtan"
        page.wait_for_timeout(500)
    return "timeout"


def _open_transaction_list(page) -> None:
    """Navigate from the dashboard into the full transaction list, which fires
    the first AccountTransactionHistory call. Falls back to the deep link."""
    try:
        page.get_by_text("Alle Umsätze", exact=False).first.click(timeout=config.ACTION_TIMEOUT_MS)
        return
    except Exception:
        pass
    try:
        page.goto(BASE + "/accounttransactionhistory/start",
                  wait_until="domcontentloaded", timeout=config.NAV_TIMEOUT_MS)
    except Exception:
        pass


def _select_long_range(page) -> None:
    """Open the 'Zeitraum' control and pick the longest range for a backfill.

    This deliberately triggers the bank's OTPRequired (mTAN) gate — releasing
    history that far back needs a second factor. The caller only does this for an
    explicit long backfill; the default 30-day path never touches this control,
    so it never provokes an mTAN.
    """
    try:
        page.get_by_text("Zeitraum", exact=False).first.click(timeout=config.ACTION_TIMEOUT_MS)
    except Exception:
        return
    # Prefer an explicit "360"/"Tage" option; otherwise take the last (longest)
    # option offered. Best-effort — selectors here are the bank's, not ours.
    for label in ("360", "Letzte 360 Tage", "Längster", "Gesamter"):
        try:
            opt = page.get_by_text(label, exact=False)
            if opt.count() > 0:
                opt.first.click(timeout=config.ACTION_TIMEOUT_MS)
                return
        except Exception:
            continue
    try:
        opts = page.get_by_role("option")
        if opts.count() > 0:
            opts.last.click(timeout=config.ACTION_TIMEOUT_MS)
    except Exception:
        pass


def _paginate(page, capture: _Capture) -> None:
    """Click 'Weitere Umsätze' until it is gone or we hit PAGE_CAP. Each click
    fires another AccountTransactionHistory call that the capture appends. LOG
    (never raise) if we stop early because of the cap."""
    for clicked in range(config.PAGE_CAP):
        try:
            more = page.get_by_role("button", name="Weitere Umsätze")
            if more.count() == 0:
                more = page.get_by_text("Weitere Umsätze", exact=False)
            if more.count() == 0 or not more.first.is_enabled():
                return
            before = len(capture.history_pages)
            more.first.click(timeout=config.ACTION_TIMEOUT_MS)
            # Wait for the click's history page to land before clicking again
            # (wait_for_timeout pumps the event loop; time.sleep would not).
            end = time.monotonic() + (config.ACTION_TIMEOUT_MS / 1000)
            while time.monotonic() < end and len(capture.history_pages) == before:
                page.wait_for_timeout(300)
        except Exception:
            return
    log.info("pagination hit PAGE_CAP=%s; transaction history may be truncated", config.PAGE_CAP)


def _build_sync_result(capture: _Capture) -> dict:
    """Hand the captured payloads to the pure normalizer. history is the list of
    captured pages (the normalizer flattens every Transactions[] it finds)."""
    return normalize.normalize(capture.landing, capture.history_pages)


# --- public surface (called from main.py via asyncio.to_thread) --------------
def login(username: str, password: str, backfill_days: int = 30) -> dict:
    """Log in. On success returns the normalized sync result (status 'ok'). If
    the bank demands an mTAN, the context is PAUSED and stored; raises
    MtanRequired carrying the pairing_id + masked hint so the user can /mtan.

    ``backfill_days`` is threaded onto the paused state so that, after an mTAN,
    /mtan resumes the exact same intended range.
    """
    _evict_expired()
    ctx = None
    try:
        # _launch() (the Chromium spawn) lives INSIDE the try so a launch failure
        # surfaces as a clean TransientError (503), not an unhandled 500.
        ctx, page = _launch()
        capture = _Capture()
        capture.attach(page)
        _fill_login(page, username, password)

        # Wait for the bank to settle into ONE of two states, pumping the event
        # loop so the RetailLanding capture actually fires.
        outcome = _await_login_outcome(page, capture, config.NAV_TIMEOUT_MS / 1000)
        if outcome == "mtan":
            # Trusted-device profiles are usually password-only; if the mTAN modal
            # shows instead, pause and hold this very context for /mtan.
            masked, reference = _mtan_hint(page)
            pairing_id = _store_pending(_Pending(ctx, page, capture, backfill_days))
            raise MtanRequired(
                "An mTAN is required to complete the login.",
                pairing_id=pairing_id, masked_phone=masked, reference=reference,
                expires_in=int(config.MTAN_TTL_S),
            )
        if outcome == "timeout":
            # No dashboard and no mTAN modal within the window => bad credentials
            # is the overwhelmingly likely cause (the bank re-renders /Login).
            raise LoginFailed("The bank rejected the username or password.")

        result = _complete_after_landing(page, capture, backfill_days)
        # Success: dashboard + history captured — close the browser (releasing the
        # profile lock). The mTAN paths below keep the context alive instead.
        _close_quietly(ctx)
        return result
    except MtanRequired:
        # Context intentionally kept alive (handed to the registry) — do NOT close.
        raise
    except ScraperError:
        _close_quietly(ctx)
        raise
    except Exception as e:  # noqa: BLE001 - any browser/network fault is transient
        _close_quietly(ctx)
        raise TransientError("Login failed due to a browser or network error.") from e


def submit_mtan(pairing_id: str, code: str) -> dict:
    """Resume the paused login context, enter the mTAN, confirm, and finish the
    sync. Returns the normalized result. A wrong code is retryable: on MtanFailed
    we re-store the context so the user can try again before the TTL.
    """
    p = _take_pending(pairing_id)
    page, capture = p.page, p.capture
    keep_alive = False
    try:
        _enter_mtan_code(page, code)

        # Pump-wait for the outcome: dashboard => success; modal still present =>
        # the code was wrong/expired (retryable).
        outcome = _await_login_outcome(page, capture, config.NAV_TIMEOUT_MS / 1000)
        if outcome == "mtan":
            keep_alive = True
            raise MtanFailed("That mTAN code was wrong or expired. Request a new one.")
        if outcome == "timeout":
            raise TransientError("The bank did not load the dashboard after the mTAN.")

        return _complete_after_landing(page, capture, p.backfill_days)
    except MtanFailed:
        raise
    except ScraperError:
        raise
    except Exception as e:  # noqa: BLE001
        raise TransientError("Failed to submit the mTAN due to a browser error.") from e
    finally:
        # On a retryable wrong-code, put it back so /mtan can be called again;
        # otherwise this login is done (success OR fatal) — close the browser.
        if keep_alive:
            with _pending_lock:
                _pending[pairing_id] = p
        else:
            _close_quietly(p.ctx)


def sync(username: str, password: str, backfill_days: int = 30) -> dict:
    """One-shot: log in and read balance + transactions for the given range.

    This is just ``login`` — which already fetches the dashboard and history —
    surfaced under the name the /sync contract uses. A long backfill_days will
    trip the bank's mTAN, propagated as MtanRequired exactly like /login; the
    default 30-day path never does.
    """
    return login(username, password, backfill_days)


# --- shared post-login path --------------------------------------------------
def _complete_after_landing(page, capture: _Capture, backfill_days: int) -> dict:
    """Dashboard is loaded. Open the transaction list, optionally widen the range
    for a backfill, paginate within PAGE_CAP, then normalize. Used by both the
    password-only login and the post-mTAN resume."""
    _open_transaction_list(page)

    if backfill_days >= config.BACKFILL_LONG_DAYS:
        # Widen to the longest range. This is expected to surface the bank's
        # OTPRequired gate (mTAN); pump briefly so the modal can render, then hand
        # the paused context to /mtan exactly like the login-time challenge.
        _select_long_range(page)
        page.wait_for_timeout(1500)
        if _looks_like_mtan(page):
            masked, reference = _mtan_hint(page)
            pairing_id = _store_pending(_Pending(page.context, page, capture, backfill_days))
            raise MtanRequired(
                "An mTAN is required to load the full transaction history.",
                pairing_id=pairing_id, masked_phone=masked, reference=reference,
                expires_in=int(config.MTAN_TTL_S),
            )

    # Give the first history page a moment to land, then paginate.
    _wait_for_history(page, capture, config.ACTION_TIMEOUT_MS / 1000)
    _paginate(page, capture)
    return _build_sync_result(capture)


def _wait_for_history(page, capture: _Capture, deadline_s: float) -> None:
    end = time.monotonic() + deadline_s
    while time.monotonic() < end and not capture.history_pages:
        page.wait_for_timeout(300)


def _enter_mtan_code(page, code: str) -> None:
    """Type the mTAN. Banks split it into per-digit boxes that auto-advance, so
    focus the first OTP box and type the whole string; fall back to a single
    field, then submit. Never logs the code."""
    typed = False
    try:
        boxes = page.locator("input[autocomplete='one-time-code'], input[inputmode='numeric'], input[maxlength='1']")
        if boxes.count() > 0:
            boxes.first.click(timeout=config.ACTION_TIMEOUT_MS)
            page.keyboard.type(code, delay=40)  # digits auto-advance across boxes
            typed = True
    except Exception:
        pass
    if not typed:
        try:
            field = page.get_by_label("mTAN")
            if field.count() == 0:
                field = page.locator("input[type='text'], input[type='tel'], input[type='password']").first
            field.fill(code, timeout=config.ACTION_TIMEOUT_MS)
        except Exception as e:
            raise TransientError("Could not locate the mTAN input field.") from e

    confirm = page.get_by_role("button", name="Bestätigen")
    if confirm.count() == 0:
        confirm = page.get_by_text("Bestätigen", exact=False).first
    confirm.click(timeout=config.ACTION_TIMEOUT_MS)
