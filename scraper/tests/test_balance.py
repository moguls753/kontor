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


def test_position_without_a_price_is_skipped():
    result = gather(
        positions=[{"instrumentId": "X", "netSize": "3"}],
        cash=[{"currencyId": "EUR", "amount": "0"}],
        details={"X": {"shortName": "X", "exchangeIds": ["LSX"]}},
        tickers={"X": None},  # no price returned
    )
    assert result["total"] == "0.00"
