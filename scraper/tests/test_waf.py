"""Unit tests for the AWS-WAF token minter in app.waf.

These fake cloakbrowser's launch_persistent_context (no real browser, no
network) and assert that mint_waf_token returns the `aws-waf-token` cookie when
WAF sets it, and raises WafMintError when the token never appears. Run inside
the built image (it ships cloakbrowser + a real Chromium):

    docker run --rm -e SIDECAR_TOKEN=test -v "$PWD/scraper/tests:/app/tests" \
      kontor-tr-scraper:dev sh -c "pip install -q pytest && python -m pytest /app/tests -q"
"""

import os

import pytest

os.environ.setdefault("SIDECAR_TOKEN", "test")

from app import waf  # noqa: E402


class FakePage:
    """Records goto() and treats wait_for_timeout as a no-op so the poll loop
    spins without sleeping (the FakeContext drives token availability)."""

    def __init__(self, ctx):
        self._ctx = ctx
        self.goto_url = None

    def goto(self, url, **kwargs):
        self.goto_url = url

    def wait_for_timeout(self, ms):
        self._ctx.ticks += 1


class FakeContext:
    """Stand-in for a cloakbrowser persistent context. Starts with no cookies;
    after ``token_after`` poll ticks it begins returning an aws-waf-token (set
    token_after=None to never produce one -> timeout)."""

    def __init__(self, token="waf-tok-123", token_after=0):
        self._token = token
        self._token_after = token_after
        self.ticks = 0
        self.closed = False
        self.pages = [FakePage(self)]

    def new_page(self):
        page = FakePage(self)
        self.pages.append(page)
        return page

    def cookies(self):
        if self._token_after is not None and self.ticks >= self._token_after:
            return [{"name": "aws-waf-token", "value": self._token}]
        return [{"name": "other", "value": "x"}]

    def close(self):
        self.closed = True


def _patch_launch(monkeypatch, ctx):
    monkeypatch.setattr(waf, "launch_persistent_context", lambda *a, **k: ctx)
    return ctx


def test_mint_returns_the_waf_token(monkeypatch):
    ctx = _patch_launch(monkeypatch, FakeContext(token="abc123", token_after=0))
    assert waf.mint_waf_token() == "abc123"
    assert ctx.closed  # context is always cleaned up
    assert ctx.pages[0].goto_url == waf.LOGIN_URL


def test_mint_polls_until_token_appears(monkeypatch):
    # Token only materializes after 2 poll ticks; the loop must keep waiting.
    ctx = _patch_launch(monkeypatch, FakeContext(token="late", token_after=2))
    assert waf.mint_waf_token() == "late"


def test_mint_times_out_when_no_token(monkeypatch):
    ctx = _patch_launch(monkeypatch, FakeContext(token_after=None))
    # Tiny deadline so the wall-clock loop exits promptly without a real sleep.
    with pytest.raises(waf.WafMintError):
        waf.mint_waf_token(deadline_s=0.05)
    assert ctx.closed


def test_mint_raises_when_browser_engine_absent(monkeypatch):
    monkeypatch.setattr(waf, "launch_persistent_context", None)
    with pytest.raises(waf.WafMintError):
        waf.mint_waf_token()


def test_mint_wraps_a_launch_failure_as_wafminterror(monkeypatch):
    # A raw browser-spawn failure must become a (retryable) WafMintError, not a
    # generic exception that escapes pair_start as a 500.
    def boom(*a, **k):
        raise RuntimeError("chromium failed to start")

    monkeypatch.setattr(waf, "launch_persistent_context", boom)
    with pytest.raises(waf.WafMintError):
        waf.mint_waf_token()


def test_mint_wraps_a_navigation_failure_and_still_closes(monkeypatch):
    # A page.goto fault must hit the inner except -> WafMintError, and the finally
    # must still close the context (no leaked Chromium).
    ctx = FakeContext()

    def boom_goto(url, **kwargs):
        raise RuntimeError("navigation failed")

    ctx.pages[0].goto = boom_goto
    _patch_launch(monkeypatch, ctx)
    with pytest.raises(waf.WafMintError):
        waf.mint_waf_token()
    assert ctx.closed
