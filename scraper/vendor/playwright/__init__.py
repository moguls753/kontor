# Intentional stub package — see sync_api.py.
#
# The real `playwright` package is NOT installed in the tr-scraper image: the
# sidecar solves the AWS WAF token with pytr's pure-Python `awswaf` path
# (waf_token="awswaf"), never the headless-Chromium path. pytr nonetheless does
# a module-level `from playwright.sync_api import sync_playwright` (pytr/api.py),
# so this stub exists only to satisfy that import.
