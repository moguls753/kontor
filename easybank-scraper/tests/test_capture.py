"""Unit tests for app.easybank's pure helpers (NO browser).

app.easybank guards its cloakbrowser import (try/except -> None), so the module
imports and its pure functions run anywhere. conftest.py puts the sidecar's app/
on sys.path. Run from the repo root:

    uv run --with pytest python -m pytest easybank-scraper/tests -q
"""

import os

# config (imported transitively by app.easybank) requires this at import time.
os.environ.setdefault("SIDECAR_TOKEN", "test")

from app import easybank  # noqa: E402


def test_has_transactions_true_on_nonempty_array_at_any_depth():
    # directive shape (Item.Transactions[]) — the long-range/post-SCA payload
    assert easybank._has_transactions({"Item": {"Transactions": [{"x": 1}]}}) is True
    # flow shape (deeply nested under InitialCallResponses) — the 30-day payload
    flow = {"Item": {"InitialCallResponses": [{"Response": {"Item": {"Transactions": [{"a": 1}]}}}]}}
    assert easybank._has_transactions(flow) is True
    # also works when the top node is a list
    assert easybank._has_transactions([{"Transactions": [{"a": 1}]}]) is True


def test_has_transactions_false_on_empty_absent_or_non_history():
    assert easybank._has_transactions({"Item": {"Transactions": []}}) is False  # empty
    assert easybank._has_transactions({"Result": {"Code": 0}}) is False  # no key
    assert easybank._has_transactions({"UnreadMessageCount": 3}) is False  # the poll
    assert easybank._has_transactions({}) is False
    assert easybank._has_transactions([]) is False
    assert easybank._has_transactions(None) is False
