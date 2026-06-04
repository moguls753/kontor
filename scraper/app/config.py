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


# Shared secret expected in the X-Sidecar-Token header on every request.
SIDECAR_TOKEN = _require("SIDECAR_TOKEN")

# tmpfs-backed scratch dir for per-request cookie jars. Never a persistent
# volume: session blobs only ever touch RAM here, and only for one request.
SESSION_SCRATCH_DIR = os.environ.get("SESSION_SCRATCH_DIR", "/scratch")

# Locale handed to Trade Republic. Only affects instrument names, not numbers.
TR_LOCALE = os.environ.get("TR_LOCALE", "en")

# Internal deadlines (seconds). These are authoritative: the sidecar returns a
# clean transient error before Rails' (deliberately longer) read timeout fires.
PAIRING_DEADLINE_S = float(os.environ.get("PAIRING_DEADLINE_S", "60"))
BALANCE_DEADLINE_S = float(os.environ.get("BALANCE_DEADLINE_S", "90"))
# Max idle wait for the next websocket message while collecting a response set.
RECV_TIMEOUT_S = float(os.environ.get("RECV_TIMEOUT_S", "15"))

# How long an in-flight pairing (start -> finish) is held in memory.
PAIRING_TTL_S = float(os.environ.get("PAIRING_TTL_S", "300"))
