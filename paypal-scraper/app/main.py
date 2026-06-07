"""FastAPI surface for the PayPal scraper sidecar.

Endpoints (all but /health require the X-Sidecar-Token header):
  GET  /health  -> {status: 'ok'}                               liveness for compose
  POST /sync    {username, password, date_from?, date_to?}      -> sync result

/sync is ONE blocking call: log in, handle the out-of-band device push (the user
is present and approves on their phone), then DOM-scrape the activity list. There
is nothing to type (the push is out-of-band), so — unlike the easybank sidecar —
there is no /login + /mtan split and no paused-context registry. Manual sync only.

The 200 body is {status: "ok", transactions: [...], balance: {amount, currency}
| null, date_from, date_to}. `balance` is the dashboard "PayPal-Guthaben" card
read best-effort post-login; it is null whenever the card is absent/unparseable
(non-critical — it never fails the sync). `amount` is a signed 2dp Decimal string,
`currency` an ISO-4217 code.

HTTP-status taxonomy (the Rails Paypal::ScraperClient depends on these; mirrors
the easybank sidecar's mapping):
  200  ok
  409  push_timeout (device push not approved in time)
  422  login_failed (bad credentials)  OR  captcha_blocked (security check)
  503  transient (timeout / browser / network) — sidecar effectively unavailable

NEVER log or return credentials, tokens, balances or counterparties in any
message/error. Request bodies are never logged.
"""

from __future__ import annotations

import asyncio
import hmac
import logging

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from . import config, paypal

# Keep third-party loggers quiet so a stray library line can never leak a URL
# with a token or any request detail. We only log our own structural facts.
logging.basicConfig(level=logging.INFO)
logging.getLogger("cloakbrowser").setLevel(logging.WARNING)
logging.getLogger("playwright").setLevel(logging.WARNING)
log = logging.getLogger("paypal-scraper")

app = FastAPI(
    title="paypal scraper",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)


# --- auth --------------------------------------------------------------------
async def require_token(x_sidecar_token: str | None = Header(default=None)) -> None:
    if not x_sidecar_token or not hmac.compare_digest(x_sidecar_token, config.SIDECAR_TOKEN):
        raise HTTPException(status_code=401, detail="invalid token")


# --- request bodies ----------------------------------------------------------
class SyncReq(BaseModel):
    username: str = Field(min_length=1)
    password: str = Field(min_length=1)
    # ISO YYYY-MM-DD; both optional (the sidecar defaults to the last 30 days).
    date_from: str | None = Field(default=None)
    date_to: str | None = Field(default=None)


# --- endpoints ---------------------------------------------------------------
@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


@app.post("/sync", dependencies=[Depends(require_token)])
async def sync(body: SyncReq) -> dict:
    # The whole browser session (login + push-block + scrape) runs in a worker
    # thread (CloakBrowser is sync), bounded by our own deadline so we return a
    # clean 503 before Rails' (deliberately longer) socket read timeout fires.
    try:
        result = await asyncio.wait_for(
            asyncio.to_thread(
                paypal.sync, body.username, body.password, body.date_from, body.date_to
            ),
            config.SYNC_DEADLINE_S,
        )
    except asyncio.TimeoutError as e:
        # The worker thread is abandoned but still holds the browser + its
        # persistent-profile SingletonLock; force-close it so the next /sync can
        # launch (else Chromium exits 21 on the stale lock).
        try:
            paypal.force_close_active()
        except Exception:  # noqa: BLE001 - best-effort cleanup, never mask the 503
            log.warning("force_close_active failed after sync timeout")
        raise paypal.TransientError("Timed out syncing PayPal activity.") from e
    return {"status": "ok", **result}


# --- error mapping -----------------------------------------------------------
# Each typed scraper error maps to the taxonomy above; anything unmapped is a 502.
_STATUS = {
    paypal.PushTimeout: 409,
    paypal.LoginFailed: 422,
    paypal.CaptchaBlocked: 422,
    paypal.TransientError: 503,
}
_CODE = {
    paypal.PushTimeout: "push_timeout",
    paypal.LoginFailed: "login_failed",
    paypal.CaptchaBlocked: "captcha_blocked",
    paypal.TransientError: "transient",
}


@app.exception_handler(paypal.ScraperError)
async def _scraper_error_handler(request: Request, exc: paypal.ScraperError) -> JSONResponse:
    status = _STATUS.get(type(exc), 502)
    code = _CODE.get(type(exc), "error")
    if status >= 500:
        log.warning("scraper error %s: %s", code, exc.message)
    return JSONResponse(status_code=status, content={"error": code, "message": exc.message})


@app.exception_handler(RequestValidationError)
async def _validation_handler(request: Request, exc: RequestValidationError) -> JSONResponse:
    # Keep the 422 body shape consistent with our scraper errors ({error, message})
    # so the Rails client can always branch on body["error"]. Surface only the
    # field LOCATIONS, never the submitted values (the body carries credentials).
    fields = ", ".join(".".join(str(p) for p in e.get("loc", [])[1:]) for e in exc.errors()) or "request"
    return JSONResponse(
        status_code=422,
        content={"error": "invalid_request", "message": f"Invalid request fields: {fields}"},
    )
