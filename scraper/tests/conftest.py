"""Make `from app import tr_api` / `from app import waf` resolve to THIS
sidecar's app/ package.

Like easybank-scraper/tests/conftest.py: run from the repo root, the Rails `app/`
there shadows ours as a namespace package, so prepend the sidecar dir on
sys.path so our regular `app` package wins regardless of working directory.

(The old vendored `playwright` stub is gone — the runtime image now ships the
real playwright as a cloakbrowser dependency, which satisfies pytr's
module-level import.)
"""

import os
import sys
import tempfile
from pathlib import Path

_root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_root))

# Config reads these at import time and fails closed without SIDECAR_TOKEN. Point
# the scratch dir (cookie jars + the throwaway WAF browser profile derive from it)
# at a writable temp dir so tests never touch the container's /scratch tmpfs.
os.environ.setdefault("SIDECAR_TOKEN", "test")
os.environ.setdefault("SESSION_SCRATCH_DIR", tempfile.mkdtemp(prefix="tr-test-scratch-"))
