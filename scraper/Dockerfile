# Trade Republic scraper sidecar.
#
# Runs network-isolated behind an allowlisting egress proxy (see compose.yml /
# compose.scraper.yml). pytr is pinned exact and installed with --no-deps so
# only the deps we curate (requirements.txt) are pulled.
#
# WAF: Trade Republic put AWS WAF Bot Control on /api/v1/auth/* (login). pytr's
# pure-Python awswaf token no longer passes (405/403). So — like the
# easybank-scraper — we ship a GENUINE stealth Chromium (CloakBrowser) and load
# the TR login page once to let AWS WAF mint a valid `aws-waf-token` cookie,
# which pytr's session then uses for initiate_weblogin. The browser is needed
# ONLY at pairing; the authenticated balance session is not WAF-gated.
#
# We base on Microsoft's Playwright image, which already carries every Chromium
# system library (fonts, nss, libgbm, …). cloakbrowser ships its OWN patched
# (stealth) Chromium (~200MB), fetched via cloakbrowser.ensure_binary(). We BAKE
# it into the image at build time (below): the runtime container is egress-locked
# to TR's hosts only (squid allowlist), so it could NOT download the browser on
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
# pytr pinned exact + --no-deps so only requirements.txt drives the dep set
# (which includes cloakbrowser + the real playwright that satisfies pytr's
# module-level playwright import).
RUN pip install --break-system-packages --no-deps pytr==0.4.9 \
 && pip install --break-system-packages -r requirements.txt

COPY app ./app

# Drop privileges. The session scratch dir + waf profile are tmpfs mounted by
# compose; the home dir holds cloakbrowser's downloaded Chromium cache.
RUN useradd --create-home --home-dir /home/scraper --uid 10001 scraper \
 && chown -R scraper:scraper /app /home/scraper
USER scraper

# Bake CloakBrowser's patched Chromium into the image AS the runtime user, so it
# caches under $HOME (/home/scraper/.cloakbrowser) and is present at runtime. MUST
# happen at build time — the egress-locked runtime can't reach the download host.
# No `|| true`: a failed fetch fails the build loudly (better than a broken image).
RUN python -c "import cloakbrowser; cloakbrowser.ensure_binary()"

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
