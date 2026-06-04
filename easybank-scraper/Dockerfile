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
# cloakbrowser ships its OWN patched (stealth) Chromium and downloads it (~200MB)
# on FIRST LAUNCH into the runtime user's home cache (HOME, below). We do NOT bake
# that 200MB binary into the image; the one-time first-request download is covered
# by the compose healthcheck's start_period, and HOME + the profile volume are
# writable for the runtime user so the lazy download lands correctly.
FROM mcr.microsoft.com/playwright/python:v1.49.0-noble

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONPATH=/app \
    # Tell cloakbrowser/playwright where to cache the downloaded browser so it
    # lands in a path the unprivileged runtime user owns.
    HOME=/home/scraper

WORKDIR /app

COPY requirements.txt .
RUN pip install --break-system-packages -r requirements.txt

COPY app ./app

# Drop privileges. The persistent profile is a rw volume mounted by compose; the
# home dir holds cloakbrowser's downloaded Chromium cache.
RUN useradd --create-home --home-dir /home/scraper --uid 10001 scraper \
 && chown -R scraper:scraper /app /home/scraper
USER scraper

# The persistent trusted-device profile. MUST be a durable rw volume, NOT tmpfs:
# losing it forces a fresh-device mTAN on every login.
VOLUME ["/profile"]

EXPOSE 8000

# xvfb-run gives Chromium a virtual display so it runs "headed" on a headless
# box (least bot-like) without a real X server. HEADLESS=true in config still
# applies; the virtual display just guarantees a working DISPLAY either way.
CMD ["xvfb-run", "-a", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
