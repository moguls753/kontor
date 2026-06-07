# PayPal personal-account scraper sidecar.
#
# Runs network-isolated behind an allowlisting egress proxy (see
# compose.paypal.yml / egress-proxy/paypal-squid.conf).
#
# Like the easybank sidecar (and UNLIKE the tr-scraper, which stubs playwright and
# uses a pure-Python WAF solver), this needs a GENUINE headless Chromium: PayPal
# runs JS device fingerprinting + reCAPTCHA Enterprise behavioral scoring, which
# only a real browser with a stable, warmed profile survives. We base on
# Microsoft's Playwright image, which already carries every Chromium system
# library (fonts, nss, libgbm, …), so a slim base's fragile
# `playwright install-deps chromium` step is avoided.
#
# cloakbrowser ships its OWN patched (stealth) Chromium (~200MB), fetched via
# cloakbrowser.ensure_binary(). We BAKE it into the image at build time (below).
# REQUIRED, not an optimization: the runtime container is egress-locked to
# PayPal's hosts only (squid allowlist), so it could NOT download the browser on
# first launch. Baking at build (open internet) makes the runtime self-contained.
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

# The persistent warmed-device profile. MUST be a durable rw volume, NOT tmpfs:
# losing it forces a fresh-device push step-up on every login + raises the captcha
# risk (a cold profile looks more bot-like).
VOLUME ["/profile"]

EXPOSE 8000

# Run headless (config HEADLESS=true; validated approach for the other sidecars).
# CloakBrowser's stealth Chromium hides the headless fingerprint; the captcha risk
# is addressed by HUMANIZE=true + a pinned PP_FINGERPRINT + Rails-side ~1/day
# rate-limiting, NOT by a virtual display. PP_FINGERPRINT is REQUIRED at runtime
# (config fails closed) — set it per install in compose.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
