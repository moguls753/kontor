"""FastAPI surface for the easybank / Barclaycard DE scraper sidecar.

Endpoints (all but /health require the X-Sidecar-Token header):
  GET  /health   -> {status: 'ok'}                       liveness for compose
  POST /login    {username, password}                    -> sync result | mtan_required
  POST /mtan     {pairing_id, code}                      -> sync result
  POST /sync     {username, password, backfill_days?=30} -> sync result

HTTP-status taxonomy (matches the Phase-2 Rails EasyBank::ScraperClient, which
mirrors TradeRepublic::ScraperClient):
  200  ok
  409  mtan_required (login needs an mTAN)  OR  session_expired (paused ctx gone)
  422  mtan_failed (wrong/expired code)     OR  login_failed (bad credentials)
  503  transient (timeout / browser / network) — sidecar effectively unavailable

NEVER log or return credentials, the mTAN code, tokens, card numbers, or
balances in any message/error. Request bodies are never logged.
"""

from __future__ import annotations

import asyncio
import hmac
import logging

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from . import config, easybank

# Keep third-party loggers quiet so a stray library debug line can never leak a
# URL with a token or any request detail. We only log our own structural facts.
logging.basicConfig(level=logging.INFO)
logging.getLogger("cloakbrowser").setLevel(logging.WARNING)
logging.getLogger("playwright").setLevel(logging.WARNING)
log = logging.getLogger("easybank-scraper")

app = FastAPI(
    title="easybank scraper",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)


# --- auth --------------------------------------------------------------------
async def require_token(x_sidecar_token: str | None = Header(default=None)) -> None:
    if not x_sidecar_token or not hmac.compare_digest(x_sidecar_token, config.SIDECAR_TOKEN):
        raise HTTPException(status_code=401, detail="invalid token")


# --- request bodies ----------------------------------------------------------
class LoginReq(BaseModel):
    username: str = Field(min_length=1)
    password: str = Field(min_length=1)


class MtanReq(BaseModel):
    pairing_id: str = Field(min_length=1)
    code: str = Field(min_length=1)


class SyncReq(BaseModel):
    username: str = Field(min_length=1)
    password: str = Field(min_length=1)
    backfill_days: int = Field(default=30, ge=1)


# --- endpoints ---------------------------------------------------------------
@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


@app.post("/login", dependencies=[Depends(require_token)])
async def login(body: LoginReq) -> dict:
    # The whole browser session runs in a worker thread (CloakBrowser is sync),
    # bounded by our own deadline so we return a clean 503 before Rails' socket
    # read timeout fires.
    try:
        result = await asyncio.wait_for(
            asyncio.to_thread(easybank.login, body.username, body.password),
            config.LOGIN_DEADLINE_S,
        )
    except asyncio.TimeoutError as e:
        raise easybank.TransientError("Timed out logging in to easybank.") from e
    return {"status": "ok", **result}


@app.post("/mtan", dependencies=[Depends(require_token)])
async def mtan(body: MtanReq) -> dict:
    try:
        result = await asyncio.wait_for(
            asyncio.to_thread(easybank.submit_mtan, body.pairing_id, body.code),
            config.MTAN_DEADLINE_S,
        )
    except asyncio.TimeoutError as e:
        raise easybank.TransientError("Timed out submitting the mTAN.") from e
    return {"status": "ok", **result}


@app.post("/sync", dependencies=[Depends(require_token)])
async def sync(body: SyncReq) -> dict:
    try:
        result = await asyncio.wait_for(
            asyncio.to_thread(easybank.sync, body.username, body.password, body.backfill_days),
            config.SYNC_DEADLINE_S,
        )
    except asyncio.TimeoutError as e:
        raise easybank.TransientError("Timed out syncing easybank transactions.") from e
    return {"status": "ok", **result}


# --- error mapping -----------------------------------------------------------
# MtanRequired is handled separately (it carries a structured body, not an
# error). The rest map to the taxonomy above; anything unmapped is a 502.
_STATUS = {
    easybank.SessionExpired: 409,
    easybank.MtanFailed: 422,
    easybank.LoginFailed: 422,
    easybank.TransientError: 503,
}
_CODE = {
    easybank.SessionExpired: "session_expired",
    easybank.MtanFailed: "mtan_failed",
    easybank.LoginFailed: "login_failed",
    easybank.TransientError: "transient",
}


@app.exception_handler(easybank.MtanRequired)
async def _mtan_required_handler(request: Request, exc: easybank.MtanRequired) -> JSONResponse:
    # 409 with a structured payload so Rails can prompt for the code. The phone
    # is already masked by the bank; we never include the full number or a code.
    return JSONResponse(
        status_code=409,
        content={
            "error": "mtan_required",
            "message": exc.message,
            "pairing_id": exc.pairing_id,
            "masked_phone": exc.masked_phone,
            "reference": exc.reference,
            "expires_in": exc.expires_in,
        },
    )


@app.exception_handler(easybank.ScraperError)
async def _scraper_error_handler(request: Request, exc: easybank.ScraperError) -> JSONResponse:
    status = _STATUS.get(type(exc), 502)
    code = _CODE.get(type(exc), "error")
    if status >= 500:
        log.warning("scraper error %s: %s", code, exc.message)
    return JSONResponse(status_code=status, content={"error": code, "message": exc.message})


@app.exception_handler(RequestValidationError)
async def _validation_handler(request: Request, exc: RequestValidationError) -> JSONResponse:
    # Keep the 422 body shape consistent with our scraper errors ({error, message})
    # so the Rails client can always branch on body["error"]. Surface only the
    # field LOCATIONS, never the submitted values (the request body carries
    # credentials and the mTAN code).
    fields = ", ".join(".".join(str(p) for p in e.get("loc", [])[1:]) for e in exc.errors()) or "request"
    return JSONResponse(
        status_code=422,
        content={"error": "invalid_request", "message": f"Invalid request fields: {fields}"},
    )
