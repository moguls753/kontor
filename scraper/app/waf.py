"""CloakBrowser AWS-WAF token minter for the Trade Republic sidecar.

TR put AWS WAF Bot Control on /api/v1/auth/* (login). pytr's pure-Python awswaf
token no longer passes (405/403). A real stealth browser solving the WAF JS
challenge mints a valid `aws-waf-token` cookie that pytr's session uses for
initiate_weblogin. Spike-confirmed: mint ~1s; only PAIRING needs it (an
authenticated balance session is not WAF-gated). Never logs secrets.
"""
from __future__ import annotations

import logging
import os
import shutil
import tempfile
import time

try:
    from cloakbrowser import launch_persistent_context
except ImportError:  # pragma: no cover - real image always has it
    launch_persistent_context = None  # type: ignore[assignment]

from . import config

log = logging.getLogger("tr-scraper")
LOGIN_URL = "https://app.traderepublic.com/login"


class WafMintError(Exception):
    """Minting the AWS WAF token failed (browser/network/timeout). Transient."""


def mint_waf_token(deadline_s: float | None = None) -> str:
    """Launch stealth Chromium, load the TR login page so AWS WAF sets
    `aws-waf-token`, and return that cookie value. Routed through the egress
    proxy; ephemeral profile (no trusted device needed). Raises WafMintError."""
    if launch_persistent_context is None:
        raise WafMintError("Browser engine is unavailable in this image.")
    deadline_s = config.WAF_MINT_DEADLINE_S if deadline_s is None else deadline_s
    kwargs: dict = {"headless": config.HEADLESS}
    if config.PROXY_URL:
        kwargs["proxy"] = {"server": config.PROXY_URL}

    # A FRESH, isolated profile per mint (under the tmpfs scratch base): two
    # overlapping pairings can't collide on Chromium's SingletonLock, and we never
    # inherit a stale lock from an unclean browser exit. Thrown away in `finally`.
    try:
        os.makedirs(config.WAF_PROFILE_DIR, exist_ok=True)
        profile = tempfile.mkdtemp(prefix="p-", dir=config.WAF_PROFILE_DIR)
    except OSError as e:
        raise WafMintError("Could not create a browser profile directory.") from e

    # The launch itself can fail (Chromium spawn / profile lock); convert it — like
    # every other fault below — into a WafMintError so pair_start surfaces a clean
    # transient (retryable) error rather than a generic 500.
    try:
        ctx = launch_persistent_context(profile, **kwargs)
    except Exception as e:  # noqa: BLE001
        shutil.rmtree(profile, ignore_errors=True)
        raise WafMintError("Could not launch the browser to mint a WAF token.") from e

    try:
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        page.goto(LOGIN_URL, wait_until="domcontentloaded", timeout=config.WAF_NAV_TIMEOUT_MS)
        end = time.monotonic() + deadline_s
        while time.monotonic() < end:
            tok = next((c["value"] for c in ctx.cookies() if c["name"] == "aws-waf-token"), None)
            if tok:
                return tok
            page.wait_for_timeout(500)  # pumps the event loop (NOT time.sleep)
        raise WafMintError("Timed out minting an AWS WAF token.")
    except WafMintError:
        raise
    except Exception as e:  # noqa: BLE001 - any browser/network fault is transient
        raise WafMintError("Browser error while minting a WAF token.") from e
    finally:
        try:
            ctx.close()
        except Exception:
            pass
        shutil.rmtree(profile, ignore_errors=True)
