"""FastAPI surface for the Trade Republic scraper sidecar.

Endpoints (all but /health require the X-Sidecar-Token header):
  GET  /health          - liveness for the compose healthcheck
  POST /pairing/start    {phone_no, pin}        -> {pairing_id, countdown_seconds, channel}
  POST /pairing/resend   {pairing_id}           -> {ok}
  POST /pairing/finish   {pairing_id, code}     -> {session_blob}
  POST /balance          {phone_no, session_blob} -> {total, currency, session_blob, as_of, warnings}
"""

from __future__ import annotations

import asyncio
import hmac
import logging
import os
import time
import uuid

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from . import config, tr_api

# pytr debug-logs the WAF token, login JSON and websocket messages. Keep it at
# WARNING so none of that ever lands in logs. Never log request bodies here.
logging.basicConfig(level=logging.INFO)
logging.getLogger("pytr").setLevel(logging.WARNING)
log = logging.getLogger("tr-scraper")

app = FastAPI(
    title="Trade Republic scraper",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)


# --- auth --------------------------------------------------------------------
async def require_token(x_sidecar_token: str | None = Header(default=None)) -> None:
    if not x_sidecar_token or not hmac.compare_digest(x_sidecar_token, config.SIDECAR_TOKEN):
        raise HTTPException(status_code=401, detail="invalid token")


# --- in-memory pairing store (start -> finish), with TTL ---------------------
class _Pairing:
    __slots__ = ("tr", "created")

    def __init__(self, tr) -> None:
        self.tr = tr
        self.created = time.monotonic()


_pairings: dict[str, _Pairing] = {}
_pairings_lock = asyncio.Lock()


def _cleanup_pairing(p: _Pairing) -> None:
    tr_api._safe_unlink(getattr(p.tr, "_cookies_file", None))


def _sweep_scratch() -> None:
    """Remove orphaned scratch files (e.g. a pairing that timed out before it was
    stored, so it is not tracked in _pairings). Files are tmpfs-backed and tiny;
    this keeps the dir self-cleaning. In-flight files are younger than the TTL
    and are left alone."""
    cutoff = time.time() - config.PAIRING_TTL_S
    try:
        with os.scandir(config.SESSION_SCRATCH_DIR) as entries:
            for entry in entries:
                try:
                    if entry.is_file() and entry.stat().st_mtime < cutoff:
                        os.remove(entry.path)
                except OSError:
                    pass
    except OSError:
        pass


async def _evict_expired() -> None:
    now = time.monotonic()
    async with _pairings_lock:
        stale = [pid for pid, p in _pairings.items() if now - p.created > config.PAIRING_TTL_S]
        for pid in stale:
            _cleanup_pairing(_pairings.pop(pid))
    _sweep_scratch()


async def _get_pairing(pairing_id: str) -> _Pairing:
    await _evict_expired()
    async with _pairings_lock:
        p = _pairings.get(pairing_id)
    if p is None:
        raise tr_api.PairingExpired("Pairing session expired. Start the pairing again.")
    return p


# --- request bodies ----------------------------------------------------------
class PairStart(BaseModel):
    phone_no: str = Field(min_length=3)
    pin: str = Field(min_length=1)


class PairFinish(BaseModel):
    pairing_id: str
    code: str = Field(min_length=1)


class BalanceReq(BaseModel):
    phone_no: str = Field(min_length=3)
    session_blob: str = Field(min_length=1)


# --- endpoints ---------------------------------------------------------------
@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


@app.post("/pairing/start", dependencies=[Depends(require_token)])
async def pairing_start(body: PairStart) -> dict:
    await _evict_expired()
    try:
        tr, countdown = await asyncio.wait_for(
            asyncio.to_thread(tr_api.pair_start, body.phone_no, body.pin),
            config.PAIRING_DEADLINE_S,
        )
    except asyncio.TimeoutError as e:
        raise tr_api.TransientError("Timed out starting Trade Republic pairing.") from e

    pairing_id = uuid.uuid4().hex
    async with _pairings_lock:
        _pairings[pairing_id] = _Pairing(tr)
    return {"pairing_id": pairing_id, "countdown_seconds": countdown, "channel": "push"}


@app.post("/pairing/finish", dependencies=[Depends(require_token)])
async def pairing_finish(body: PairFinish) -> dict:
    p = await _get_pairing(body.pairing_id)
    # A wrong/expired code is retryable: keep the pairing so the user can enter a
    # new code. Only consume it on success.
    blob = await asyncio.to_thread(tr_api.pair_finish, p.tr, body.code)
    async with _pairings_lock:
        _pairings.pop(body.pairing_id, None)
    _cleanup_pairing(p)
    return {"session_blob": blob}


@app.post("/balance", dependencies=[Depends(require_token)])
async def balance(body: BalanceReq) -> dict:
    return await tr_api.fetch_balance(body.phone_no, body.session_blob)


# --- error mapping -----------------------------------------------------------
_STATUS = {
    tr_api.SessionExpired: 409,
    tr_api.PairingExpired: 410,
    tr_api.PairingFailed: 422,
    tr_api.TransientError: 503,
}
_CODE = {
    tr_api.SessionExpired: "SESSION_EXPIRED",
    tr_api.PairingExpired: "PAIRING_EXPIRED",
    tr_api.PairingFailed: "PAIRING_FAILED",
    tr_api.TransientError: "TRANSIENT",
}


@app.exception_handler(tr_api.ScraperError)
async def _scraper_error_handler(request: Request, exc: tr_api.ScraperError) -> JSONResponse:
    status = _STATUS.get(type(exc), 502)
    code = _CODE.get(type(exc), "ERROR")
    if status >= 500:
        log.warning("scraper error %s: %s", code, exc.message)
    return JSONResponse(status_code=status, content={"error": code, "message": exc.message})
