"""Unit tests for app.paypal's import-safety + error taxonomy (NO browser).

app.paypal guards its cloakbrowser import (try/except -> None), so the module
imports and its pure surface is inspectable anywhere. conftest.py puts the
sidecar's app/ on sys.path. Run from the repo root:

    uv run --with pytest python -m pytest paypal-scraper/tests -q
"""

import os

# config (imported transitively by app.paypal) requires these at import time.
os.environ.setdefault("SIDECAR_TOKEN", "test")
os.environ.setdefault("PP_FINGERPRINT", "61803")

from app import paypal  # noqa: E402


def test_error_taxonomy_classes_exist_and_carry_safe_message():
    for cls in (paypal.LoginFailed, paypal.CaptchaBlocked, paypal.PushTimeout, paypal.TransientError):
        assert issubclass(cls, paypal.ScraperError)
        e = cls("safe message")
        assert e.message == "safe message"


def test_sync_returns_transient_when_browser_unavailable(monkeypatch):
    # In the test env cloakbrowser isn't installed, so launch_persistent_context
    # is None and _launch() must surface a clean TransientError (503), never a 500.
    monkeypatch.setattr(paypal, "launch_persistent_context", None)
    try:
        paypal.sync("user", "pass", "2026-05-01", "2026-06-01")
        assert False, "expected a TransientError"
    except paypal.TransientError as e:
        assert "browser" in e.message.lower() or "unavailable" in e.message.lower()


# --- _scrape_rows emits interleaved header markers in document order ---------
# A tiny fake of the Playwright locator API, just enough for _scrape_rows:
# page.locator(sel) -> _Loc with .count()/.nth(i); each element exposes
# .get_attribute("class") and .locator("[data-testid='..']").first.inner_text().
class _Inner:
    def __init__(self, text):
        self._text = text
        self.first = self

    def count(self):
        return 1 if self._text is not None else 0

    def inner_text(self, timeout=None):
        return self._text or ""


class _El:
    def __init__(self, *, cls="", testids=None, text=""):
        self._cls = cls
        self._testids = testids or {}
        self._text = text

    def get_attribute(self, name):
        if name == "class":
            return self._cls
        return ""

    def inner_text(self, timeout=None):
        return self._text

    def locator(self, selector):
        # selector is "[data-testid='counterparty_name']" etc.
        key = selector.split("'")[1] if "'" in selector else selector
        return _Inner(self._testids.get(key))


class _Loc:
    def __init__(self, els):
        self._els = els

    def count(self):
        return len(self._els)

    def nth(self, i):
        return self._els[i]


class _Page:
    """Returns the COMBINED row-or-header node list for the _ROW_OR_HEADER
    selector (the only selector _scrape_rows queries)."""
    def __init__(self, nodes):
        self._nodes = nodes

    def locator(self, selector):
        return _Loc(self._nodes)


def _tx_el(txid, amount_text, description_text, merchant="Shop", notes=""):
    return _El(
        cls=f"foo js_transactionItem-{txid} bar",
        testids={
            "counterparty_name": merchant,
            "transaction_amount": amount_text,
            "transaction_description": description_text,
            "transaction-notes": notes,
        },
    )


def _header_el(text):
    # A header carries NO js_transactionItem- class -> _is_header() True.
    return _El(cls="listBucketHeader_completed", text=text)


# --- read_balance: parses the PayPal-Guthaben card, None when absent ---------
class _BalanceAnchor:
    """Fake page.get_by_text(...).first whose ancestor xpath locators yield the
    card's inner_text. .locator(xpath) returns an _Inner-like with inner_text."""
    def __init__(self, card_text):
        self._card_text = card_text
        self.first = self

    def count(self):
        return 1

    def locator(self, xpath):
        # Only the widened ancestor scopes carry the full card text; the heading
        # element itself ("xpath=.") has just the label, no amount.
        text = self._card_text if xpath != "xpath=." else "PayPal-Guthaben"
        return _Inner(text)


class _BalancePage:
    def __init__(self, card_text=None):
        self._card_text = card_text

    def locator(self, selector):
        # Real card exposes the amount at data-test-id="available-balance" (the
        # primary, verified hook). Model it from the card text; parse_balance
        # extracts the amount from whatever text it is given. Other selectors / no
        # card -> count() == 0 so read_balance falls through to the heading walk.
        if "available-balance" in selector and self._card_text is not None:
            return _Inner(self._card_text)
        return _Inner(None)

    def get_by_text(self, needle, exact=False):
        if self._card_text is None:
            return _Loc([])  # no card -> count() == 0
        return _BalanceAnchor(self._card_text)


def test_read_balance_parses_guthaben_card():
    # The card fragment: heading, then the amount (U+00A0 nbsp), then "Verfügbar".
    page = _BalancePage("PayPal-Guthaben\n0,00 €\nVerfügbar")
    assert paypal.read_balance(page) == {"amount": "0.00", "currency": "EUR"}


def test_read_balance_returns_none_when_card_absent():
    # No PayPal-Guthaben card -> None, and it must NOT raise (non-critical).
    assert paypal.read_balance(_BalancePage(card_text=None)) is None


def test_scrape_rows_emits_headers_interleaved_and_feeds_year_carry():
    from datetime import date
    from app import normalize

    # Newest-first document order: a "Jan. 2026" month header, a Jan row, then a
    # "Dez. 2025" header and a Dez row. The interleaved markers are what let the
    # year-carry resolve 2026 vs 2025 across a >30-day window.
    nodes = [
        _header_el("Jan. 2026"),
        _tx_el("J1", "\u22121,00 \u20ac", "3. Jan. . Zahlung"),
        _header_el("Dez. 2025"),
        _tx_el("D1", "\u22122,00 \u20ac", "30. Dez. . Zahlung"),
    ]
    raw = paypal._scrape_rows(_Page(nodes))

    # The scrape itself produced the header markers (not hand-fed).
    assert raw[0] == {"header": "Jan. 2026"}
    assert raw[2] == {"header": "Dez. 2025"}
    assert raw[1]["id"] == "J1"

    recs = normalize.normalize(raw, "2025-06-07", "2026-06-06", today=date(2026, 6, 6))
    by = {r["id"]: r for r in recs}
    assert by["J1"]["booking_date"] == "2026-01-03"
    assert by["D1"]["booking_date"] == "2025-12-30"


def test_year_carry_future_guard_when_dec_header_missing():
    # Regression: PayPal didn't emit a "Dez. 2025" header, so the carry is a stale
    # "Mai 2026". The future-guard must still resolve "30. Dez." to 2025 (a booked
    # tx is never in the future) instead of 2026-12-30 (which aborted the sync).
    from datetime import date
    from app import normalize

    nodes = [
        _header_el("Mai 2026"),
        _tx_el("M1", "−1,00 €", "5. Mai . Zahlung"),
        _tx_el("D1", "−2,00 €", "30. Dez. . Zahlung"),  # no Dez header before it
    ]
    raw = paypal._scrape_rows(_Page(nodes))
    recs = normalize.normalize(raw, "2025-06-07", "2026-06-07", today=date(2026, 6, 7))
    by = {r["id"]: r for r in recs}
    assert by["M1"]["booking_date"] == "2026-05-05"
    assert by["D1"]["booking_date"] == "2025-12-30"  # stepped back, not 2026


def test_normalize_skips_out_of_window_row_instead_of_aborting():
    # A genuinely out-of-window row is skipped (logged), NOT fatal — one bad row
    # must never kill the whole year sync.
    from datetime import date
    from app import normalize

    nodes = [
        _header_el("Juni 2024"),  # before date_from -> out of window
        _tx_el("OLD", "−1,00 €", "5. Juni . Zahlung"),
        _header_el("Mai 2026"),
        _tx_el("OK", "−2,00 €", "5. Mai . Zahlung"),
    ]
    raw = paypal._scrape_rows(_Page(nodes))
    recs = normalize.normalize(raw, "2025-06-07", "2026-06-07", today=date(2026, 6, 7))
    ids = {r["id"] for r in recs}
    assert "OK" in ids and "OLD" not in ids
