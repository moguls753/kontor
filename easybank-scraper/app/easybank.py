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
def _has_transactions(body) -> bool:
    """True if a decoded JSON payload carries a non-empty Transactions[] array
    anywhere. The long-range / post-SCA history can arrive under a different op
    name than AccountTransactionHistory, so we detect it by shape, not URL."""
    stack = [body]
    while stack:
        node = stack.pop()
        if isinstance(node, dict):
            txs = node.get("Transactions")
            if isinstance(txs, list) and txs:
                return True
            stack.extend(node.values())
        elif isinstance(node, list):
            stack.extend(node)
    return False


class _Capture:
    """Accumulates the JSON the Angular app fetches. RetailLanding overwrites
    (one dashboard); history accumulates so paginated "Weitere Umsätze" pages are
    all retained for normalization. `dropped` counts transaction-bearing bank
    responses we failed to decode, so a silently-dropped page can be turned into a
    hard error instead of a short result; `truncated` flags that pagination hit
    PAGE_CAP (the history may be incomplete)."""

    __slots__ = ("landing", "history_pages", "dropped", "truncated")

    def __init__(self) -> None:
        self.landing: dict | None = None
        self.history_pages: list[dict] = []
        self.dropped: int = 0
        self.truncated: bool = False

    def attach(self, page) -> None:
        def on_response(resp) -> None:
            url = resp.url
            try:
                if "/services/flow/RetailLanding" in url:
                    self.landing = resp.json()
                    return
                if "/services/flow/AccountTransactionHistory" in url:
                    self.history_pages.append(resp.json())
                    return
                # The long-range / post-SCA history arrives under a different op
                # (TransactionViewDirective/GetTransactions), so capture by shape —
                # but ONLY from the bank's own origin, never a third party (the
                # egress allowlist also permits the fingerprint host).
                if resp.request.method == "POST" and url.startswith(BASE):
                    body = resp.json()
                    if _has_transactions(body):
                        self.history_pages.append(body)
            except Exception:
                # A non-JSON / partially-read body is normally just a miss. But a
                # bank transaction endpoint we couldn't decode is a SILENTLY
                # DROPPED history page — record it so the caller fails loud rather
                # than returning a short payload as success. Never re-raise into
                # Playwright's event loop.
                try:
                    if resp.request.method == "POST" and url.startswith(BASE) and "Transaction" in url:
                        self.dropped += 1
                except Exception:
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


def _select_range(page, option_name: str, native_needle: str) -> None:
    """Pick a 'Zeitraum' option. The control is a Select2 widget over a hidden
    native <select id="select-DateRangeSelectorCombobox"> (options 0=30d,
    1=since-statement, 2=90d, 3=180d, 4="Letzten 360 Tage", 5=custom). Drive the
    visible widget like a human; fall back to setting the native value and firing
    change for both the native binding and Select2 (which binds through jQuery)."""
    try:
        page.locator("#select2-select-DateRangeSelectorCombobox-container").click(timeout=config.ACTION_TIMEOUT_MS)
    except Exception:
        try:
            page.get_by_label("Zeitraum").click(timeout=config.ACTION_TIMEOUT_MS)
        except Exception:
            pass
    try:
        page.get_by_role("option", name=option_name).click(timeout=config.ACTION_TIMEOUT_MS)
        return
    except Exception:
        pass
    try:
        page.evaluate(
            """(needle) => {
                 const s = document.querySelector('#select-DateRangeSelectorCombobox');
                 if (!s) return;
                 const o = Array.from(s.options).find(x => x.text.includes(needle));
                 if (o) { s.value = o.value; }
                 s.dispatchEvent(new Event('change', { bubbles: true }));
                 if (window.jQuery) window.jQuery(s).trigger('change');
               }""",
            native_needle,
        )
    except Exception:
        pass


def _select_long_range(page) -> None:
    """Pick 'Letzten 360 Tage'. This deliberately trips the bank's OTPRequired
    (mTAN) gate — releasing history that far back needs a second factor. Only the
    explicit long backfill calls this; the default 30-day path never does, so it
    never provokes an mTAN."""
    _select_range(page, "Letzten 360 Tage", "360")


def _find_more_button(page):
    """Locate the 'show more transactions' control, returning it only if visible
    AND enabled (a disabled-but-visible button is the end-of-history state — bail
    instantly instead of burning a click + timeout). The label varies: match the
    full unambiguous phrases by role or text, but the SHORT generic terms by
    button ROLE only — a get_by_text('Mehr') substring would hit unrelated UI like
    'Mehr Infos' / 'Weitere Konten' and click the wrong element."""
    candidates = []
    for name in ("Mehr anzeigen", "Weitere Umsätze", "Mehr laden"):
        candidates.append(page.get_by_role("button", name=name))
        candidates.append(page.get_by_text(name, exact=False))
    for name in ("Mehr", "Weitere"):
        candidates.append(page.get_by_role("button", name=name))
    for loc in candidates:
        try:
            if loc.count() and loc.first.is_visible() and loc.first.is_enabled():
                return loc.first
        except Exception:
            continue
    return None


def _paginate(page, capture: _Capture) -> None:
    """Smash the 'show more' button until it is gone, a click yields no new page,
    or we hit PAGE_CAP. Each click fires another history call the capture appends."""
    for _ in range(config.PAGE_CAP):
        more = _find_more_button(page)
        if more is None:
            return
        try:
            before = len(capture.history_pages)
            more.click(timeout=config.ACTION_TIMEOUT_MS)
            # wait_for_timeout pumps the event loop so the captured page lands;
            # time.sleep would not.
            end = time.monotonic() + (config.ACTION_TIMEOUT_MS / 1000)
            while time.monotonic() < end and len(capture.history_pages) == before:
                page.wait_for_timeout(300)
            if len(capture.history_pages) == before:
                return  # click produced no new page -> end of history
        except Exception:
            return
    capture.truncated = True
    log.warning("pagination hit PAGE_CAP=%s; transaction history may be truncated", config.PAGE_CAP)


def _build_sync_result(capture: _Capture) -> dict:
    """Hand the captured payloads to the pure normalizer. history is the list of
    captured pages (the normalizer flattens every Transactions[] it finds).

    Fail loud if a bank transaction page was dropped (undecodable) rather than
    returning a short result as success; surface a `truncated` flag if pagination
    hit PAGE_CAP so the caller knows the history may be incomplete."""
    if capture.dropped:
        raise TransientError(
            f"{capture.dropped} transaction page(s) could not be decoded; "
            "retrying to avoid ingesting a truncated history."
        )
    result = normalize.normalize(capture.landing, capture.history_pages)
    if capture.truncated:
        result["truncated"] = True
    return result


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
    handed_off = False
    try:
        _enter_mtan_code(page, code)
        log.info("mtan: code submitted; waiting for the modal to clear")

        # The code is correct iff the modal clears; a modal that persists past the
        # window => a wrong/expired code (retryable).
        deadline = time.monotonic() + config.NAV_TIMEOUT_MS / 1000
        while time.monotonic() < deadline and _looks_like_mtan(page):
            page.wait_for_timeout(500)
        if _looks_like_mtan(page):
            keep_alive = True
            log.info("mtan: modal still present -> wrong/expired code")
            raise MtanFailed("That mTAN code was wrong or expired. Request a new one.")

        # Code accepted. Two shapes:
        #  (A) range-select mTAN (the live-verified common path): the list is
        #      already open and the bank now AUTO-loads the long range ("Einen
        #      Moment Geduld", Zeitraum still 360) — wait for the released history
        #      (arrives via the TransactionViewDirective, captured by shape), then
        #      paginate. Do NOT touch the range control.
        #  (B) login-time mTAN: we paused BEFORE the transaction list was ever
        #      opened (_await_login_outcome saw the modal), so nothing auto-loads.
        #      Detect that (no new page) and run the normal post-landing flow —
        #      open the list, widen for a backfill — exactly like the password-only
        #      login, instead of silently returning an empty result.
        log.info("mtan: accepted; waiting for the long-range history to load")
        before = len(capture.history_pages)
        deadline = time.monotonic() + config.NAV_TIMEOUT_MS / 1000
        while time.monotonic() < deadline and len(capture.history_pages) <= before:
            page.wait_for_timeout(500)
        if len(capture.history_pages) == before:
            log.info("mtan: nothing auto-loaded (login-time mTAN) -> completing the landing flow")
            try:
                return _complete_after_landing(page, capture, p.backfill_days)
            except MtanRequired:
                # Widening to the long range re-tripped the gate; _complete_after_
                # landing re-stored THIS context under a new pairing, so finally
                # must NOT close it.
                handed_off = True
                raise
        log.info("mtan: history pages now %s (was %s)", len(capture.history_pages), before)
        _paginate(page, capture)
        return _build_sync_result(capture)
    except MtanFailed:
        raise
    except ScraperError:
        raise
    except Exception as e:  # noqa: BLE001
        raise TransientError("Failed to submit the mTAN due to a browser error.") from e
    finally:
        # On a retryable wrong-code, put it back so /mtan can be called again.
        # If the range gate re-tripped, the context was handed to a NEW pairing —
        # leave it open. Otherwise this login is done (success OR fatal) — close it.
        if keep_alive:
            with _pending_lock:
                _pending[pairing_id] = p
        elif not handed_off:
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
    """Enter the mTAN and submit. The bank shows six per-digit boxes, but those
    (#OTPPassword-Char*) are DISABLED display mirrors — the real, validated input
    is the single #OTPPassword-Full-field. Fill it (fall back to a generic numeric
    field), then click Bestätigen. Never logs the code."""
    # Fill #OTPPassword-Full-field (the validated input, proven live). The Char
    # boxes are disabled mirrors — .fill() on them just blocks the full
    # actionability timeout — so we don't try them; a generic numeric field is the
    # only fallback.
    entered = False
    try:
        full = page.locator("#OTPPassword-Full-field")
        if full.count():
            full.first.fill(code, timeout=config.ACTION_TIMEOUT_MS)
            entered = True
            log.info("mtan: filled OTPPassword-Full-field")
    except Exception as e:
        log.info("mtan: full-field fill failed: %s", type(e).__name__)
    if not entered:
        try:
            field = page.get_by_label("mTAN")
            if field.count() == 0:
                field = page.locator("input[inputmode='numeric'], input[type='tel']")
            field.first.fill(code, timeout=config.ACTION_TIMEOUT_MS)
            log.info("mtan: filled generic field")
        except Exception as e:
            raise TransientError("Could not locate the mTAN input field.") from e

    page.wait_for_timeout(400)  # let the widget validate / enable the submit button
    confirm = page.get_by_role("button", name="Bestätigen")
    if confirm.count() == 0:
        confirm = page.get_by_text("Bestätigen", exact=False).first
    confirm.click(timeout=config.ACTION_TIMEOUT_MS)
