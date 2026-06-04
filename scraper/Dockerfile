# Trade Republic scraper sidecar.
#
# Runs network-isolated behind an allowlisting egress proxy (see
# compose.scraper.yml). pytr is pinned exact and installed with --no-deps so its
# `playwright` dependency is never pulled in; a stub under vendor/ satisfies
# pytr's module-level import while the pure-Python awswaf solver does the work.
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONPATH=/app:/app/vendor

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-deps pytr==0.4.9 \
 && pip install -r requirements.txt

COPY vendor ./vendor
COPY app ./app

# Drop privileges. The session scratch dir is a tmpfs mounted by compose.
RUN useradd --create-home --uid 10001 scraper
USER scraper

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
