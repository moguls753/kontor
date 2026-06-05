"""Runtime configuration, read entirely from the environment.

Nothing sensitive is baked into the image. The sidecar fails closed: it
refuses to start without a shared-secret token.
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

# tmpfs-backed scratch dir for per-request cookie jars. Never a persistent
# volume: session blobs only ever touch RAM here, and only for one request.
SESSION_SCRATCH_DIR = os.environ.get("SESSION_SCRATCH_DIR", "/scratch")

# Locale handed to Trade Republic. Only affects instrument names, not numbers.
TR_LOCALE = os.environ.get("TR_LOCALE", "en")

# --- AWS WAF token minting (pairing only) ------------------------------------
# TR gates the login (/api/v1/auth/*) behind AWS WAF Bot Control. A real stealth
# Chromium (app/waf.py) loads the login page so WAF sets an `aws-waf-token`
# cookie, which pytr's session uses for initiate_weblogin. Browser-only at
# pairing — the authenticated balance session is not WAF-gated.

# Run Chromium headless. Default true: validated live against the real WAF.
HEADLESS = _bool("HEADLESS", True)

# Optional egress proxy. In compose this points at the tr-egress-proxy so the
# browser's ONLY route off the box is the squid CONNECT allowlist. Empty =>
# direct (e.g. local live-validation on the user's own machine).
PROXY_URL = os.environ.get("PROXY_URL") or None

# Base dir for the WAF-minting browser's throwaway profiles. Unlike easybank, TR
# needs NO trusted device, so each mint gets a FRESH ephemeral sub-profile under
# here (see app/waf.py) and it is thrown away after. Derived from the tmpfs
# scratch dir so it always follows any scratch remap.
WAF_PROFILE_DIR = os.environ.get("WAF_PROFILE_DIR") or os.path.join(SESSION_SCRATCH_DIR, "waf-profile")

# How long to poll for the `aws-waf-token` cookie before giving up (seconds).
WAF_MINT_DEADLINE_S = float(os.environ.get("WAF_MINT_DEADLINE_S", "45"))

# Per-navigation Playwright timeout (ms) for loading the TR login page. Kept below
# the mint deadline (the spike showed ~1s loads) so a slow page can't eat the
# whole pairing budget.
WAF_NAV_TIMEOUT_MS = int(os.environ.get("WAF_NAV_TIMEOUT_MS", "30000"))

# Internal deadlines (seconds). These are authoritative: the sidecar returns a
# clean transient error before Rails' (deliberately longer) read timeout fires.
# Pairing is 120 (was 60): launching the browser + minting the token adds ~1-3s.
PAIRING_DEADLINE_S = float(os.environ.get("PAIRING_DEADLINE_S", "120"))
BALANCE_DEADLINE_S = float(os.environ.get("BALANCE_DEADLINE_S", "90"))
# Max idle wait for the next websocket message while collecting a response set.
RECV_TIMEOUT_S = float(os.environ.get("RECV_TIMEOUT_S", "15"))

# How long an in-flight pairing (start -> finish) is held in memory.
PAIRING_TTL_S = float(os.environ.get("PAIRING_TTL_S", "300"))
