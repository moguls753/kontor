# easybank / Barclaycard DE scraper sidecar.
#
# Runs network-isolated behind an allowlisting egress proxy (see
# compose.easybank.yml).
#
# DIVERGENCE FROM THE TR IMAGE: the tr-scraper intentionally STUBS playwright and
# ships no browser (it uses a pure-Python WAF solver over a websocket). This
# sidecar instead needs a GENUINE headless Chromium — easybank fingerprints the
# device and gates on a trusted-device cookie that only a real browser
# reproduces. So we base on Microsoft's Playwright image, which already carries
# every Chromium system library (fonts, nss, libgbm, …) plus xvfb. That removes
# the fragile `playwright install-deps chromium` step a slim base would need.
#
# cloakbrowser ships its OWN patched (stealth) Chromium (~200MB), fetched via
# cloakbrowser.ensure_binary(). We BAKE it into the image at build time (below).
# This is REQUIRED, not an optimization: the runtime container is egress-locked to
# the bank's hosts only (squid allowlist), so it could NOT download the browser on
# first launch — the download host isn't allowlisted. Baking at build (open
# internet) makes the runtime self-contained.
FROM mcr.microsoft.com/playwright/python:v1.49.0-noble

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONPATH=/app \
    # Disable CloakBrowser's background auto-update: it fires daemon threads that
    # hit PyPI/GitHub — useless for an egress-locked runtime (those hosts aren't
    # allowlisted), and at build time a daemon thread mid-request segfaults the
    # interpreter on exit. Off => no threads, clean build + no runtime phone-home.
    CLOAKBROWSER_AUTO_UPDATE=false \
    # Tell cloakbrowser/playwright where to cache the downloaded browser so it
    # lands in a path the unprivileged runtime user owns.
    HOME=/home/scraper

WORKDIR /app

COPY requirements.txt .
RUN pip install --break-system-packages -r requirements.txt

COPY app ./app

# Drop privileges. The persistent profile is a rw volume mounted by compose; the
# home dir holds cloakbrowser's downloaded Chromium cache. We pre-create + chown
# /profile so a FRESH named volume inherits scraper ownership (Docker copies the
# image dir's owner into an empty volume) — otherwise Chromium can't write its
# SingletonLock there as the non-root user and the launch aborts (exit 21).
RUN useradd --create-home --home-dir /home/scraper --uid 10001 scraper \
 && mkdir -p /profile \
 && chown -R scraper:scraper /app /home/scraper /profile
USER scraper

# Bake CloakBrowser's patched Chromium into the image AS the runtime user, so it
# caches under $HOME (/home/scraper/.cloakbrowser) and is present at runtime. MUST
# happen at build time — the egress-locked runtime can't reach the download host.
# No `|| true`: a failed fetch fails the build loudly (better than a broken image).
RUN python -c "import cloakbrowser; cloakbrowser.ensure_binary()"

# The persistent trusted-device profile. MUST be a durable rw volume, NOT tmpfs:
# losing it forces a fresh-device mTAN on every login.
VOLUME ["/profile"]

EXPOSE 8000

# Run headless (config HEADLESS=true): CloakBrowser's stealth Chromium needs NO
# display in this mode (validated live against the real bank), so uvicorn runs
# directly. We dropped the xvfb-run wrapper — as PID 1 it started Xvfb but never
# brought uvicorn up and swallowed its stdout (empty logs). If HEADED mode is ever
# wanted for extra stealth, reintroduce a virtual display (and fix the wrapper) then.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
