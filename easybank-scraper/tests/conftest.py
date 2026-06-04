"""Make `from app import normalize` resolve to THIS sidecar's app/ package.

When pytest runs from the repo root (e.g. the documented
`python -m pytest easybank-scraper/tests`), the repo root is on sys.path and the
Rails `app/` directory there shadows our `app/` as a namespace package, so
`from app import normalize` fails with "cannot import name 'normalize'". Putting
the sidecar dir first on sys.path makes our regular `app` package win, so the
tests import the right module no matter the working directory.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
