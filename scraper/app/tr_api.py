"""Thin wrapper around pytr's TradeRepublicApi.

The sidecar does two jobs:

1. **Pairing** — a 2-step web login (`initiate_weblogin` triggers an app push,
   `complete_weblogin(code)` confirms it). The resulting session is just a
   `cookies.txt` jar, returned base64-encoded as an opaque ``session_blob``.
2. **Balance** — restore that cookie session (no PIN, no 2FA) and read the
   account's total balance. No transactions are fetched.

Design notes
------------
* We never call pytr's interactive ``account.login()`` (it uses input()/getpass);
  we drive ``TradeRepublicApi`` directly.
* TR gates the login (/api/v1/auth/*) behind AWS WAF Bot Control. pytr's
  pure-Python ``awswaf`` token no longer passes, so ``app.waf`` mints a valid
  ``aws-waf-token`` with a real stealth Chromium (CloakBrowser) and we hand it
  to pytr for ``initiate_weblogin``. The browser is needed ONLY at pairing; the
  authenticated balance session is not WAF-gated (no token, no browser).
* pytr keeps subscription bookkeeping (``subscriptions``,
  ``_previous_responses``, ``_subscription_id_counter``, ``_lock``) as *class*
  attributes shared across instances. We shadow them per-instance so one
  request's websocket state can never bleed into another's.
* Balance is pytr's proven portfolio computation, ported without the
  printing/CSV: ``cash(EUR) + Σ(price × netSize)``, using instrument details
  for the correct exchange and bond (price ÷ 100) handling.
"""

from __future__ import annotations

import asyncio
import base64
import os
import re
import tempfile
from datetime import datetime, timezone
from decimal import ROUND_HALF_UP, Decimal

import requests
from pytr.api import TradeRepublicApi, TradeRepublicError

from . import config


# --- error taxonomy: each maps to a distinct HTTP status in main.py ----------
class ScraperError(Exception):
    """Base class. ``message`` is safe to surface and never contains secrets."""

    def __init__(self, message: str):
        super().__init__(message)
        self.message = message


class SessionExpired(ScraperError):
    """Saved cookie session is no longer valid (TR returned 401/403)."""


class PairingExpired(ScraperError):
    """The in-flight pairing id is unknown — sidecar restart or TTL elapsed."""


class PairingFailed(ScraperError):
    """User-actionable pairing failure (wrong phone/PIN, or wrong/expired code)."""


class TransientError(ScraperError):
    """Upstream 5xx, network error, WAF failure or timeout — retry, never re-pair."""


# Bond names look like "... Jan 2027"; their ticker price is per €100 face
# value. Copied verbatim from pytr/portfolio.py to match its computation.
_BOND_PATTERN = re.compile(
    r"(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec|January|February|March|"
    r"April|May|June|July|August|September|October|November|December|Januar|"
    r"Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|"
    r"Dezember)\.?\s+20\d{2}",
    re.IGNORECASE,
)

# pytr requires a non-empty pin to construct the client, but the balance path is
# cookie-only (resume_websession) and never transmits it.
_PLACEHOLDER_PIN = "0000"


def _build_api(phone_no: str, pin: str, cookies_file: str, waf_token=None) -> TradeRepublicApi:
    tr = TradeRepublicApi(
        phone_no=phone_no,
        pin=pin,
        locale=config.TR_LOCALE,
        save_cookies=True,
        cookies_file=cookies_file,
        waf_token=waf_token,
    )
    # pytr stores these as class attributes; shadow them per-instance so this
    # request's websocket bookkeeping cannot bleed into another request's.
    tr.subscriptions = {}
    tr._previous_responses = {}
    tr._subscription_id_counter = 1
    tr._lock = asyncio.Lock()
    return tr


def _read_blob(path) -> str:
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode("ascii")


def _safe_unlink(path) -> None:
    try:
        os.remove(path)
    except OSError:
        pass


def _scratch_file(prefix: str) -> str:
    fd, path = tempfile.mkstemp(prefix=prefix, suffix=".txt", dir=config.SESSION_SCRATCH_DIR)
    os.close(fd)
    os.chmod(path, 0o600)
    return path


# --- pairing (2-step weblogin) -----------------------------------------------
def pair_start(phone_no: str, pin: str) -> tuple[TradeRepublicApi, int]:
    """Initiate weblogin: solve the WAF token (slow, synchronous) and trigger
    the app push. Returns the live api instance (to hold for completion) and the
    resend countdown in seconds. Raises PairingFailed / TransientError."""
    cookies_file = _scratch_file("tr-pair-")
    # AWS WAF Bot Control gates /api/v1/auth/* — mint a valid `aws-waf-token`
    # with a real stealth browser (pytr's pure-Python awswaf no longer passes)
    # and hand it to pytr's session for initiate_weblogin.
    from . import waf

    try:
        waf_token = waf.mint_waf_token()
    except waf.WafMintError as e:
        _safe_unlink(cookies_file)
        raise TransientError("Could not obtain a Trade Republic login challenge.") from e
    tr = _build_api(phone_no, pin, cookies_file, waf_token=waf_token)
    try:
        countdown = tr.initiate_weblogin()
    except ValueError as e:
        # pytr raises ValueError(errors) for e.g. a rejected phone/PIN.
        _safe_unlink(cookies_file)
        raise PairingFailed("Trade Republic rejected the phone number or PIN.") from e
    except requests.exceptions.HTTPError as e:
        _safe_unlink(cookies_file)
        status = getattr(e.response, "status_code", None)
        if status in (400, 401, 403):
            raise PairingFailed("Trade Republic rejected the phone number or PIN.") from e
        raise TransientError(f"Trade Republic login failed (HTTP {status}).") from e
    except requests.exceptions.RequestException as e:
        _safe_unlink(cookies_file)
        raise TransientError("Could not reach Trade Republic to start pairing.") from e
    except Exception as e:  # WAF solve failure, etc.
        _safe_unlink(cookies_file)
        raise TransientError("Could not obtain a Trade Republic login challenge.") from e
    return tr, int(countdown)


def pair_finish(tr: TradeRepublicApi, code: str) -> str:
    """Complete weblogin with the 2FA code; persist and return the session blob.
    Raises PairingFailed (wrong/expired code — retryable) / TransientError."""
    try:
        tr.complete_weblogin(code)  # also calls save_websession()
    except requests.exceptions.HTTPError as e:
        status = getattr(e.response, "status_code", None)
        if status in (400, 401, 403, 404):
            raise PairingFailed("That code was wrong or expired. Request a new one.") from e
        raise TransientError(f"Trade Republic rejected the code (HTTP {status}).") from e
    except requests.exceptions.RequestException as e:
        raise TransientError("Could not reach Trade Republic to confirm the code.") from e
    return _read_blob(tr._cookies_file)


# --- balance -----------------------------------------------------------------
async def fetch_balance(phone_no: str, session_blob: str) -> dict:
    """Restore the saved session and read the account's total balance.

    Cookie-only: no PIN, no 2FA. Returns ``total`` (string, 2dp), ``currency``,
    a refreshed ``session_blob``, ``as_of``, and any ``warnings``. Any
    unexpected failure is surfaced as a TransientError so a flaky upstream is
    never mistaken for an expired session.
    """
    cookies_file = _scratch_file("tr-bal-")
    with open(cookies_file, "wb") as f:
        f.write(base64.b64decode(session_blob))

    tr = _build_api(phone_no, _PLACEHOLDER_PIN, cookies_file)
    try:
        # 1. Classify session liveness over HTTP (precise 401/403 vs transient).
        await asyncio.to_thread(_probe_session, tr)
        # 2. Gather the balance over the websocket, bounded by our own deadline.
        result = await asyncio.wait_for(_gather_balance(tr), config.BALANCE_DEADLINE_S)
        # 3. Persist refreshed cookies and read them back BEFORE cleanup.
        await asyncio.to_thread(tr.save_websession)
        result["session_blob"] = _read_blob(cookies_file)
        result["as_of"] = datetime.now(timezone.utc).isoformat()
        return result
    except ScraperError:
        raise
    except asyncio.TimeoutError as e:
        raise TransientError("Timed out fetching the Trade Republic balance.") from e
    except Exception as e:
        raise TransientError("Unexpected error fetching the Trade Republic balance.") from e
    finally:
        try:
            await tr.close()
        except Exception:
            pass
        _safe_unlink(cookies_file)


def _probe_session(tr: TradeRepublicApi) -> None:
    """Load the cookie jar and verify it with a lightweight authenticated GET.

    Mirrors pytr's resume_websession(), but classifies the failure so a
    transient 5xx is never mistaken for an expired (401/403) session.
    """
    try:
        tr._websession.cookies.load(ignore_discard=True)
    except OSError as e:  # missing/corrupt jar (http.cookiejar.LoadError is an OSError)
        raise SessionExpired("Stored Trade Republic session is unreadable; re-pair required.") from e
    try:
        tr.settings()  # GET /api/v2/auth/account (+ session refresh), raise_for_status
    except requests.exceptions.HTTPError as e:
        status = getattr(e.response, "status_code", None)
        if status in (401, 403):
            raise SessionExpired("Trade Republic session has expired; re-pair required.") from e
        raise TransientError(f"Trade Republic session probe failed (HTTP {status}).") from e
    except requests.exceptions.RequestException as e:
        raise TransientError("Could not reach Trade Republic to verify the session.") from e


async def _gather_balance(tr: TradeRepublicApi) -> dict:
    sub_compact = await tr.compact_portfolio()
    sub_cash = await tr.cash()
    responses, _ = await _collect(tr, {sub_compact, sub_cash})

    if sub_cash not in responses:
        raise TransientError("Trade Republic did not return a cash balance.")
    cash_buckets = responses[sub_cash]

    # compactPortfolio missing => it errored, i.e. a cash-only account.
    positions = responses.get(sub_compact, {}).get("positions", []) or []
    securities_value = await _securities_value(tr, positions)

    # cash() returns a list of {currencyId, amount} buckets.
    warnings: list[str] = []
    eur = next((b for b in cash_buckets if b.get("currencyId") == "EUR"), None)
    if eur is not None:
        cash_value = Decimal(str(eur.get("amount", "0")))
    else:
        cash_value = Decimal("0")
        warnings.append("no_eur_cash_bucket")
    non_eur = sorted(
        b.get("currencyId", "?")
        for b in cash_buckets
        if b.get("currencyId") != "EUR" and _nonzero(b.get("amount"))
    )
    if non_eur:
        warnings.append("non_eur_cash_present:" + ",".join(non_eur))

    total = (cash_value + securities_value).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    return {"total": str(total), "currency": "EUR", "warnings": warnings}


async def _securities_value(tr: TradeRepublicApi, positions: list) -> Decimal:
    """Replicates pytr's portfolio_loop value computation (sans printing/CSV)."""
    if not positions:
        return Decimal("0")

    # Only HELD positions need valuing. A closed-but-still-listed position has netSize 0 and
    # contributes price×0 = 0, so it is excluded from BOTH the math and the fail-loud check
    # below (else a dropped price for an irrelevant 0-size row would needlessly refuse the
    # whole balance forever). A real SELL-OFF leaves no held positions -> genuine cash returned.
    held = [p for p in positions if Decimal(str(p.get("netSize", "0"))) != 0]
    if not held:
        return Decimal("0")

    # Instrument details give the correct exchange and the name (bond handling).
    detail_subs = {await tr.instrument_details(p["instrumentId"]): p for p in held}
    details, _ = await _collect(tr, set(detail_subs))
    for sid, pos in detail_subs.items():
        d = details.get(sid) or {}
        pos["_name"] = d.get("shortName", "")
        pos["_exchanges"] = d.get("exchangeIds", []) or []

    # Tickers give the current price; use the first listed exchange (per pytr).
    ticker_subs = {}
    for pos in held:
        if pos["_exchanges"]:
            ticker_subs[await tr.ticker(pos["instrumentId"], exchange=pos["_exchanges"][0])] = pos
    tickers, _ = await _collect(tr, set(ticker_subs))

    priced: dict = {}  # instrumentId -> (price, pos)
    for sid, pos in ticker_subs.items():
        ticker = tickers.get(sid)
        if not ticker or "price" not in (ticker.get("last") or {}):
            continue  # price didn't arrive -> caught by the completeness check below
        priced[pos["instrumentId"]] = (Decimal(str(ticker["last"]["price"])), pos)

    # FAIL-LOUD on an INCOMPLETE feed (the cash-only bug). Every HELD position must be fully
    # valued. One that wasn't priced — whether its instrument_details response dropped (-> no
    # exchange -> never subscribed), its details came back with no exchange, OR its ticker price
    # never arrived — means TR's WebSocket dropped part of the feed (flaky behind the AWS WAF;
    # both stages go through the same straggler-tolerant _collect). pytr silently skips it,
    # collapsing securities toward 0 and reporting a 5-figure portfolio as cash-only (observed
    # 12.330,47 € -> 11,52 €). A partial total is worse than none: refuse it (-> 503 TRANSIENT)
    # so the caller retries / keeps the last good value. A real SELL-OFF (held == []) returned
    # the genuine cash above and never reaches here, so this can't misfire on a liquidation.
    unpriced = [p.get("_name") or p["instrumentId"] for p in held if p["instrumentId"] not in priced]
    if unpriced:
        raise TransientError(
            f"Incomplete Trade Republic price feed: {len(unpriced)}/{len(held)} "
            f"held position(s) unpriced ({', '.join(map(str, unpriced[:5]))}); refusing a partial total."
        )

    total = Decimal("0")
    for price, pos in priced.values():
        if _BOND_PATTERN.search(pos.get("_name", "")):
            price = price / 100  # bond price is per €100 face value
        net_size = Decimal(str(pos.get("netSize", "0")))
        total += (price * net_size).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    return total


async def _collect(tr: TradeRepublicApi, sub_ids: set) -> tuple[dict, dict]:
    """Receive responses for the given subscription ids, tolerating per-sub
    errors and stragglers (mirrors pytr's portfolio_loop behaviour)."""
    results: dict = {}
    errors: dict = {}
    pending = set(sub_ids)
    while pending:
        try:
            sid, _sub, resp = await asyncio.wait_for(tr.recv(), config.RECV_TIMEOUT_S)
        except asyncio.TimeoutError:
            break  # give up on stragglers
        except TradeRepublicError as e:
            if e.subscription_id in pending:
                pending.discard(e.subscription_id)
                errors[e.subscription_id] = e
            continue
        if sid in pending:
            results[sid] = resp
            pending.discard(sid)
            await tr.unsubscribe(sid)
    return results, errors


def _nonzero(amount) -> bool:
    try:
        return Decimal(str(amount)) != 0
    except (ArithmeticError, ValueError, TypeError):
        return False
