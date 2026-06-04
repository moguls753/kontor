"""Runtime configuration, read entirely from the environment.

Nothing sensitive is baked into the image. The sidecar fails closed: it
refuses to start without a shared-secret token. Mirrors scraper/app/config.py.
"""

import os


def _require(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"{name} must be set")
    return value


def _bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


# Shared secret expected in the X-Sidecar-Token header on every request.
SIDECAR_TOKEN = _require("SIDECAR_TOKEN")

# CloakBrowser's persistent context dir — this IS the trusted-device store, so
# (unlike the TR sidecar's tmpfs scratch) it MUST survive restarts on a real rw
# volume, or every login would face a fresh-device mTAN. See compose.easybank.yml.
PROFILE_DIR = os.environ.get("PROFILE_DIR", "/profile")

# Run Chromium headless. Default true: the image runs it under xvfb on a virtual
# display so the bank still sees a "headed" browser (least bot-like), while we
# need no real X server. Set false only for local debugging on a desktop.
HEADLESS = _bool("HEADLESS", True)

# Optional egress proxy. In compose this points at the easybank egress-proxy so
# the browser's ONLY route off the box is the squid CONNECT allowlist. Empty =>
# direct (e.g. local live-validation on the user's own machine).
PROXY_URL = os.environ.get("PROXY_URL") or None

# Hard cap on "Weitere Umsätze" (load-more) pagination clicks during a sync. A
# safety valve: a 360-day backfill on a busy card could otherwise loop forever.
# If we hit the cap we LOG it and return what we have rather than spin.
PAGE_CAP = int(os.environ.get("PAGE_CAP", "25"))

# Internal deadlines (seconds). These are authoritative: the sidecar returns a
# clean transient error before Rails' (deliberately longer) read timeout fires.
LOGIN_DEADLINE_S = float(os.environ.get("LOGIN_DEADLINE_S", "120"))
SYNC_DEADLINE_S = float(os.environ.get("SYNC_DEADLINE_S", "180"))
MTAN_DEADLINE_S = float(os.environ.get("MTAN_DEADLINE_S", "120"))

# Per-action Playwright timeout (ms) for locator fills/clicks/waits.
ACTION_TIMEOUT_MS = int(os.environ.get("ACTION_TIMEOUT_MS", "15000"))
# How long to wait for the dashboard's RetailLanding JSON after submitting creds
# (or an mTAN code) before treating it as a failure.
NAV_TIMEOUT_MS = int(os.environ.get("NAV_TIMEOUT_MS", "45000"))

# How long a paused, mTAN-pending browser context is held in memory between
# /login and /mtan. Matches the bank's own code validity; a sweeper closes any
# context that outlives it so neither Chromium processes nor the registry leak.
MTAN_TTL_S = float(os.environ.get("MTAN_TTL_S", "300"))

# Hard ceiling on simultaneously-paused mTAN logins. A safety valve so a burst of
# /login calls can't accumulate live browser contexts; over this, the oldest
# paused context is closed and dropped. Single-user in practice, so small.
MAX_PENDING = int(os.environ.get("MAX_PENDING", "8"))

# Backfill day-count that selects the bank's longest "Zeitraum" range. The bank
# requires an mTAN to release history that far back (OTPRequired). The default
# 30-day path must NEVER trigger one.
BACKFILL_LONG_DAYS = int(os.environ.get("BACKFILL_LONG_DAYS", "360"))
