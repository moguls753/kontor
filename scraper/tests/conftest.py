"""Make `from app import tr_api` resolve to THIS sidecar's app/ package, and put
the vendored playwright stub on the path (pytr imports playwright at import time).

Like easybank-scraper/tests/conftest.py: run from the repo root, the Rails `app/`
there shadows ours, so prepend the sidecar dir. The sidecar also runs pytr against
a vendored `playwright` stub (the Dockerfile sets PYTHONPATH=/app:/app/vendor), so
add vendor/ too.
"""

import sys
from pathlib import Path

_root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_root / "vendor"))
sys.path.insert(0, str(_root))
