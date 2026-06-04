"""Stub for `playwright.sync_api` — see this package's __init__.py.

We never use Playwright (waf_token="awswaf"), but pytr imports `sync_playwright`
at module load. This shim satisfies that import and fails loudly if the
Playwright code path is ever actually reached.
"""


def sync_playwright(*args, **kwargs):  # noqa: D401 - intentional failure
    raise RuntimeError(
        "playwright is intentionally not installed in the tr-scraper image; "
        "the AWS WAF token is solved with pytr's pure-Python 'awswaf' path. "
        "Reaching this means waf_token != 'awswaf' — fix the call site."
    )
