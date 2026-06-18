"""Unit tests for the balance computation in app.tr_api.

These exercise the pure portfolio math (cash + Σ price×netSize, bond ÷100,
exchange selection, missing-price skip, EUR/non-EUR handling) against a fake
TradeRepublicApi, with no network. Run inside the built image:

    docker run --rm -e SIDECAR_TOKEN=test -v "$PWD/scraper/tests:/app/tests" \
      kontor-tr-scraper:dev sh -c "pip install -q pytest && python -m pytest /app/tests -q"
"""

import asyncio
import os

os.environ.setdefault("SIDECAR_TOKEN", "test")

from app import tr_api  # noqa: E402
from pytr.api import TradeRepublicError  # noqa: E402


class FakeTr:
    """Scriptable stand-in for pytr's TradeRepublicApi. Each subscribe-like call
    enqueues the response recv() will later yield (FIFO), mirroring how
    _gather_balance subscribes-then-collects in phases."""

    def __init__(self, positions=None, cash=None, details=None, tickers=None, compact_error=False):
        self._positions = positions or []
        self._cash = cash or []
        self._details = details or {}
        self._tickers = tickers or {}
        self._compact_error = compact_error
        self._counter = 0
        self._queue = []

    def _next(self):
        self._counter += 1
        return str(self._counter)

    async def compact_portfolio(self):
        sid = self._next()
        if self._compact_error:
            self._queue.append(TradeRepublicError(sid, {"type": "compactPortfolio"}, {"message": "no securities account"}))
        else:
            self._queue.append((sid, {"type": "compactPortfolio"}, {"positions": self._positions}))
        return sid

    async def cash(self):
        sid = self._next()
        self._queue.append((sid, {"type": "cash"}, self._cash))
        return sid

    async def instrument_details(self, isin):
        sid = self._next()
        self._queue.append((sid, {"type": "instrument"}, self._details.get(isin, {})))
        return sid

    async def ticker(self, isin, exchange="LSX"):
        sid = self._next()
        price = self._tickers.get(isin)
        resp = {"last": {"price": price}} if price is not None else {}
        self._queue.append((sid, {"type": "ticker"}, resp))
        return sid

    async def recv(self):
        if not self._queue:
            raise asyncio.TimeoutError()  # no more messages -> _collect breaks
        item = self._queue.pop(0)
        if isinstance(item, TradeRepublicError):
            raise item
        return item

    async def unsubscribe(self, sid):
        pass


def gather(**kwargs):
    return asyncio.run(tr_api._gather_balance(FakeTr(**kwargs)))


def test_total_is_cash_plus_securities_with_bond_handling():
    result = gather(
        positions=[
            {"instrumentId": "STOCK", "netSize": "10"},
            {"instrumentId": "BOND1", "netSize": "5"},
        ],
        cash=[{"currencyId": "EUR", "amount": "100.00"}],
        details={
            "STOCK": {"shortName": "Acme", "exchangeIds": ["LSX"]},
            "BOND1": {"shortName": "Bund Jan 2027", "exchangeIds": ["LSX"]},
        },
        tickers={"STOCK": "20.00", "BOND1": "100.00"},  # bond price is per €100 face -> ÷100
    )
    # cash 100 + stock 20*10=200 + bond (100/100)*5 = 5  =>  305.00
    assert result["total"] == "305.00"
    assert result["currency"] == "EUR"
    assert result["warnings"] == []


def test_cash_only_account_has_zero_securities():
    result = gather(compact_error=True, cash=[{"currencyId": "EUR", "amount": "50.00"}])
    assert result["total"] == "50.00"
    assert result["warnings"] == []


def test_non_eur_cash_is_flagged():
    result = gather(cash=[{"currencyId": "EUR", "amount": "10.00"}, {"currencyId": "USD", "amount": "5.00"}])
    assert result["total"] == "10.00"
    assert any(w.startswith("non_eur_cash_present") and "USD" in w for w in result["warnings"])


def test_missing_eur_bucket_is_flagged_and_total_is_zero():
    result = gather(cash=[{"currencyId": "USD", "amount": "5.00"}])
    assert result["total"] == "0.00"
    assert "no_eur_cash_bucket" in result["warnings"]


def test_position_with_missing_price_fails_loud_not_silent_cash_only():
    # The cash-only bug: a HELD position whose ticker price didn't arrive used to be silently
    # dropped, collapsing the portfolio to cash-only. It must now FAIL LOUD (503/TRANSIENT) so
    # the caller keeps the last good value instead of booking a wrong (undervalued) total.
    import pytest
    with pytest.raises(tr_api.TransientError):
        gather(
            positions=[{"instrumentId": "X", "netSize": "3"}],
            cash=[{"currencyId": "EUR", "amount": "0"}],
            details={"X": {"shortName": "X", "exchangeIds": ["LSX"]}},
            tickers={"X": None},  # subscribed, but no price came back -> incomplete feed
        )


def test_partial_price_feed_fails_rather_than_undervaluing():
    # One position priced, one not -> the total would be undervalued (cash + A only). Refuse it.
    import pytest
    with pytest.raises(tr_api.TransientError):
        gather(
            positions=[
                {"instrumentId": "A", "netSize": "10"},
                {"instrumentId": "B", "netSize": "5"},
            ],
            cash=[{"currencyId": "EUR", "amount": "100.00"}],
            details={
                "A": {"shortName": "A", "exchangeIds": ["LSX"]},
                "B": {"shortName": "B", "exchangeIds": ["LSX"]},
            },
            tickers={"A": "20.00", "B": None},  # B's price missing -> partial -> must fail
        )


def test_real_sell_off_writes_the_genuine_cash_through_no_false_positive():
    # Sold everything: compactPortfolio returns NO holdings, so securities == 0 legitimately and
    # the real (small) cash balance is returned — NOT rejected. This is what distinguishes a real
    # liquidation from the cash-leak: no positions => no ticker subscribed => nothing to fail on.
    result = gather(positions=[], cash=[{"currencyId": "EUR", "amount": "11.52"}])
    assert result["total"] == "11.52"
    assert result["warnings"] == []


def test_dropped_instrument_details_fails_loud_not_silent_cash_only():
    # The cash-leak one stage EARLIER: the same flaky WAF/WebSocket can drop a HELD position's
    # instrument_details response (-> empty details -> no exchange -> never subscribed for a
    # ticker). That must STILL fail loud, not silently collapse to cash-only.
    import pytest
    with pytest.raises(tr_api.TransientError):
        gather(
            positions=[{"instrumentId": "X", "netSize": "100"}],
            cash=[{"currencyId": "EUR", "amount": "11.52"}],
            details={"X": {}},  # details dropped/empty -> no exchangeIds -> unpriced held position
            tickers={},
        )


def test_held_position_without_exchange_fails_loud():
    # A held position whose details arrived but list no tradable exchange can't be priced via
    # ticker — refuse a partial total rather than silently omit its value.
    import pytest
    with pytest.raises(tr_api.TransientError):
        gather(
            positions=[{"instrumentId": "X", "netSize": "50"}],
            cash=[{"currencyId": "EUR", "amount": "100.00"}],
            details={"X": {"shortName": "X", "exchangeIds": []}},
            tickers={},
        )


def test_zero_size_position_with_missing_price_does_not_fail():
    # A closed-but-still-listed position has netSize 0 and contributes 0 — a missing price for it
    # must NOT refuse the whole (otherwise fully-knowable) balance. The real held position prices.
    result = gather(
        positions=[
            {"instrumentId": "Z", "netSize": "0"},   # closed; price irrelevant (×0)
            {"instrumentId": "A", "netSize": "10"},
        ],
        cash=[{"currencyId": "EUR", "amount": "100.00"}],
        details={
            "Z": {"shortName": "Z", "exchangeIds": ["LSX"]},
            "A": {"shortName": "A", "exchangeIds": ["LSX"]},
        },
        tickers={"A": "20.00", "Z": None},  # Z unpriced but netSize 0 -> ignored
    )
    assert result["total"] == "300.00"  # cash 100 + A 20*10
    assert result["warnings"] == []
