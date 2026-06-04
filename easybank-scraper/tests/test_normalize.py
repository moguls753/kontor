"""Unit tests for app.normalize — the pure VeriChannel -> /sync mapping.

PURE Python, NO browser: app.normalize imports nothing from cloakbrowser/
playwright, so these run anywhere. The fixtures mirror the REAL easybank shape
observed live (a key reason the first cut was wrong): transaction magnitudes are
UNSIGNED with the direction in TransactionNature; BookingDate is the .NET min-
date until a row is booked; IsPending is always false and the real pending signal
is TransactionType == "Pending". Run from the repo root (conftest.py puts the
sidecar's app/ first on sys.path):

    uv run --with pytest python -m pytest easybank-scraper/tests -q
"""

import json
import os
from pathlib import Path

# config.py requires this at import time; normalize doesn't import config, but
# set it defensively so the test is import-order independent.
os.environ.setdefault("SIDECAR_TOKEN", "test")

from app import normalize  # noqa: E402

FIXTURES = Path(__file__).parent / "fixtures"


def _load(name):
    return json.loads((FIXTURES / name).read_text())


def _result():
    landing = _load("retail_landing.json")
    history = _load("transaction_history.json")
    # main passes the captured history as a LIST of pages; the normalizer must
    # cope with that, so exercise it the same way here.
    return normalize.normalize(landing, [history])


def _by_id(result, tx_id):
    return next(t for t in result["transactions"] if t["id"] == tx_id)


def test_balance_and_available_from_landing():
    result = _result()
    # CurrentBalance keeps the bank's own sign (balances ARE signed).
    assert result["balance"] == {"value": "-123.45", "currency": "EUR"}
    assert result["available"] == {"value": "1876.55", "currency": "EUR"}


def test_account_mapping():
    acct = _result()["account"]
    assert acct["iban"] == "DE00100100001234567890"
    assert acct["number"] == "1234567890"
    assert acct["name"] == "Barclays Visa"
    assert acct["type"] == "CreditCard"
    assert acct["credit_limit"] == {"value": "2000.00", "currency": "EUR"}
    assert acct["available_credit"] == {"value": "1876.55", "currency": "EUR"}


def test_all_transactions_collected_and_otp_flag():
    result = _result()
    assert len(result["transactions"]) == 5
    assert result["otp_required"] is False


def test_domestic_eur_debit_signs_from_nature_and_dates_fall_back():
    tx = _by_id(_result(), "900001")
    # Unsigned 26.80 + TransactionNature "Debit" => negative.
    assert tx["amount"] == "-26.80"
    assert tx["currency"] == "EUR"
    assert tx["original_amount"] == "-26.80"
    assert tx["original_currency"] == "EUR"
    # BookingDate is the min-date => fall back to PostingDate; value_date <- ValueDate.
    assert tx["booking_date"] == "2026-05-31"
    assert tx["value_date"] == "2026-05-30"
    assert tx["merchant"] == "REWE"
    assert tx["mcc"] == "5411"
    assert tx["is_pending"] is False
    assert tx["type"] == "Debit"
    # Domestic => no FX rate (the bank's 0.0 is dropped).
    assert tx["exchange_rate"] is None


def test_foreign_usd_debit_splits_eur_settled_vs_original_foreign():
    tx = _by_id(_result(), "900002")
    assert tx["amount"] == "-49.55"
    assert tx["currency"] == "EUR"
    assert tx["original_amount"] == "-54.32"
    assert tx["original_currency"] == "USD"
    assert tx["exchange_rate"] == 0.9123
    assert tx["merchant"] == "Amazon US"  # from nested MerchantData.Name
    assert tx["booking_date"] == "2026-05-28"  # no PostingDate => ValueDate


def test_credit_keeps_positive_sign():
    tx = _by_id(_result(), "900003")
    assert tx["amount"] == "418.39"
    assert tx["currency"] == "EUR"
    assert tx["type"] == "Credit"
    assert tx["is_pending"] is False
    assert tx["booking_date"] == "2026-05-25"  # billed => real BookingDate


def test_pending_uses_transaction_type_and_reference_id():
    # No InternalID => id falls back to ReferenceNumber. Pending comes from
    # TransactionType == "Pending" (NOT the always-false IsPending).
    tx = _by_id(_result(), "REF-900004")
    assert tx["is_pending"] is True
    assert tx["amount"] == "-12.99"
    assert tx["value_date"] == "2026-06-01"
    assert tx["booking_date"] == "2026-06-01"  # Booking + Posting min => ValueDate
    assert tx["merchant"] == "dm"


def test_sign_falls_back_to_formatted_amount_when_nature_missing():
    # No TransactionNature; the sign must come from FormattedLocalAmount "-7,77 €".
    tx = _by_id(_result(), "900005")
    assert tx["amount"] == "-7.77"
    assert tx["type"] is None


def test_empty_inputs_are_safe():
    result = normalize.normalize(None, [])
    assert result["balance"] is None
    assert result["available"] is None
    assert result["transactions"] == []
    assert result["account"]["iban"] is None
    assert result["otp_required"] is False
