"""Unit tests for app.normalize — the pure PayPal-row -> /sync mapping.

PURE Python, NO browser: app.normalize imports nothing from cloakbrowser/
playwright, so these run anywhere. The fixtures mirror the REAL PayPal activity
DOM observed live in tmp/paypal-activity.html (the reason the first cuts were
wrong): date+type are FUSED in transaction_description split on " . "; amounts use
the U+2212 minus + U+00A0 nbsp and a German locale; FX rows show ONLY the foreign
amount with a trailing ISO token; the only header is a STATUS header
("Abgeschlossen"), so rows derive their year from today (future => prev year).
conftest.py puts the sidecar's app/ first on sys.path. Run from the repo root:

    uv run --with pytest python -m pytest paypal-scraper/tests -q
"""

import os
from datetime import date

# config.py requires these at import time; normalize doesn't import config, but
# set them defensively so the test is import-order independent.
os.environ.setdefault("SIDECAR_TOKEN", "test")
os.environ.setdefault("PP_FINGERPRINT", "61803")

from app import normalize  # noqa: E402

# A fixed "today" so the year-carry tests are deterministic. The saved fixture's
# newest row is "6. Juni" under an "Abgeschlossen" status header.
TODAY = date(2026, 6, 6)
WINDOW = ("2025-06-07", "2026-06-06")  # a ~1y window that contains the fixture


def _norm(rows, window=WINDOW, today=TODAY):
    return normalize.normalize(rows, window[0], window[1], today=today)


# --- amount parsing ----------------------------------------------------------
def test_amount_negative_euro_u2212_and_nbsp():
    # "−8,15 €" uses U+2212 (typographic minus) + U+00A0 (nbsp).
    assert normalize.parse_amount("−8,15 €") == __import__("decimal").Decimal("-8.15")
    assert normalize.parse_currency("−8,15 €") == "EUR"


def test_amount_positive_euro_no_sign():
    assert str(normalize.parse_amount("79,00 €")) == "79.00"


def test_amount_foreign_prefers_trailing_iso_token():
    # "−10,60 $ USD": amount is the foreign value, currency is the trailing ISO.
    assert str(normalize.parse_amount("−10,60 $ USD")) == "-10.60"
    assert normalize.parse_currency("−10,60 $ USD") == "USD"


def test_amount_thousands_separator():
    assert str(normalize.parse_amount("−1.234,56 €")) == "-1234.56"


def test_amount_grouped_zero_decimal_jpy_not_1000x_too_small():
    # "5.000 \u00a5" is five thousand yen (zero-decimal, grouped) -- NOT 5.00. The
    # bare "\\d+" alternative would have stripped the dot of a "5" => 5.00.
    assert str(normalize.parse_amount("5.000 \u00a5")) == "5000.00"
    assert normalize.parse_currency("5.000 \u00a5") == "JPY"


def test_amount_grouped_integer_euro_no_decimal():
    # "1.234 \u20ac" is one-thousand-two-hundred-thirty-four euros, not 1.00.
    assert str(normalize.parse_amount("1.234 \u20ac")) == "1234.00"


def test_amount_bare_integer_still_parses():
    assert str(normalize.parse_amount("79 \u20ac")) == "79.00"


# --- balance (PayPal-Guthaben card) ------------------------------------------
def test_parse_balance_zero_euro_card_fragment():
    # The card fragment uses the nbsp + the heading/Verfügbar copy around it.
    frag = "PayPal-Guthaben\n0,00 €\nVerfügbar"
    assert normalize.parse_balance(frag) == {"amount": "0.00", "currency": "EUR"}


def test_parse_balance_nonzero_and_foreign():
    assert normalize.parse_balance("1.234,56 €") == {"amount": "1234.56", "currency": "EUR"}
    assert normalize.parse_balance("−10,60 $ USD") == {"amount": "-10.60", "currency": "USD"}


def test_parse_balance_returns_none_without_amount():
    assert normalize.parse_balance("PayPal-Guthaben Verfügbar") is None
    assert normalize.parse_balance("") is None


# --- description split (date . type) -----------------------------------------
def test_description_splits_on_space_dot_space_not_abbrev_dot():
    assert normalize.split_description("6. Juni . Zahlung") == ("6. Juni", "Zahlung")
    # The abbreviation dot in "Apr." must NOT be the split point.
    assert normalize.split_description("29. Apr. . Zahlung") == ("29. Apr.", "Zahlung")
    assert normalize.split_description("31. März . Zahlung im Einzugsverfahren") == (
        "31. März",
        "Zahlung im Einzugsverfahren",
    )


# --- end-to-end row mapping --------------------------------------------------
def _row(**over):
    row = {
        "id": "55X63072JY995300U",
        "merchant": "eBay S.a.r.l.",
        "amount_text": "−8,15 €",
        "description_text": "6. Juni . Zahlung",
        "notes": "",
    }
    row.update(over)
    return row


def test_basic_row_wire_contract():
    [rec] = _norm([_row()])
    assert set(rec) == {"id", "merchant", "description", "amount", "currency",
                        "booking_date", "is_pending"}
    assert rec["id"] == "55X63072JY995300U"
    assert rec["merchant"] == "eBay S.a.r.l."
    assert rec["description"] == "Zahlung"
    assert rec["amount"] == "-8.15"
    assert rec["currency"] == "EUR"
    assert rec["booking_date"] == "2026-06-06"
    assert rec["is_pending"] is False


def test_foreign_row_books_foreign_amount_and_iso():
    [rec] = _norm([_row(amount_text="−10,60 $ USD", description_text="3. Juni . Zahlung")])
    assert rec["amount"] == "-10.60"
    assert rec["currency"] == "USD"


def test_is_pending_is_always_false_booked_only():
    recs = _norm([_row(), _row(id="3X467854PV031762A", description_text="4. Juni . Zahlung im Einzugsverfahren")])
    assert all(r["is_pending"] is False for r in recs)


# --- synthetic id ------------------------------------------------------------
def test_idless_row_gets_stable_synthetic_id():
    a = _norm([_row(id="")])[0]
    b = _norm([_row(id="")])[0]
    assert a["id"].startswith("pp-syn-")
    assert a["id"] == b["id"]


def test_idless_rows_with_different_content_differ():
    a = _norm([_row(id="", amount_text="−1,00 €")])[0]
    b = _norm([_row(id="", amount_text="−2,00 €")])[0]
    assert a["id"] != b["id"]


def test_present_id_is_used_verbatim():
    [rec] = _norm([_row(id="ABC123XYZ")])
    assert rec["id"] == "ABC123XYZ"


# --- year-carry --------------------------------------------------------------
def test_header_less_leading_bucket_uses_current_year():
    # The newest rows sit under a STATUS header ("Abgeschlossen"), which carries
    # no year — so "6. Juni" with today=2026-06-06 resolves to 2026.
    rows = [{"header": "Abgeschlossen"}, _row(description_text="6. Juni . Zahlung")]
    [rec] = _norm(rows)
    assert rec["booking_date"] == "2026-06-06"


def test_future_month_day_steps_back_a_year():
    # No header carries a year; "8. Dez." with today=2026-06-06 is in the future
    # for 2026, so it must resolve to 2025-12-08 (Dec->Jan boundary guard).
    win = ("2025-06-07", "2026-06-06")
    [rec] = normalize.normalize(
        [_row(id="DEC1", amount_text="−5,00 €", description_text="8. Dez. . Zahlung")],
        win[0], win[1], today=TODAY,
    )
    assert rec["booking_date"] == "2025-12-08"


def test_month_year_header_carries_year():
    # An explicit "Dez. 2025" header pins the year for the rows beneath it; a
    # later "Jan. 2026" header flips it (Dez->Jan boundary across the walk).
    rows = [
        {"header": "Jan. 2026"},
        _row(id="J1", amount_text="−1,00 €", description_text="3. Jan. . Zahlung"),
        {"header": "Dez. 2025"},
        _row(id="D1", amount_text="−2,00 €", description_text="30. Dez. . Zahlung"),
    ]
    win = ("2025-06-07", "2026-06-06")
    recs = normalize.normalize(rows, win[0], win[1], today=TODAY)
    by = {r["id"]: r for r in recs}
    assert by["J1"]["booking_date"] == "2026-01-03"
    assert by["D1"]["booking_date"] == "2025-12-30"


def test_status_header_does_not_overwrite_carried_year():
    # A "Diese Woche"/"Abgeschlossen" status header must NOT clear a previously
    # carried month-header year.
    rows = [
        {"header": "Dez. 2025"},
        {"header": "Abgeschlossen"},
        _row(id="D2", amount_text="−2,00 €", description_text="30. Dez. . Zahlung"),
    ]
    win = ("2025-06-07", "2026-06-06")
    [rec] = normalize.normalize(rows, win[0], win[1], today=TODAY)
    assert rec["booking_date"] == "2025-12-30"


# --- fail-loud ---------------------------------------------------------------
def test_unparseable_amount_raises():
    import pytest
    with pytest.raises(ValueError):
        _norm([_row(amount_text="")])


def test_unparseable_date_raises():
    import pytest
    with pytest.raises(ValueError):
        _norm([_row(description_text="kein Datum . Zahlung")])


def test_date_outside_window_is_rejected():
    import pytest
    # "6. Juni" -> 2026-06-06 but the window ends 2026-06-05 => out of bounds.
    with pytest.raises(ValueError):
        normalize.normalize([_row()], "2026-05-01", "2026-06-05", today=TODAY)


def test_empty_rows_is_empty():
    assert _norm([]) == []


# --- currency fail-loud (LOW #9) ---------------------------------------------
def test_unparseable_currency_raises():
    import pytest
    # A figure with no symbol and no ISO token has no resolvable currency; the
    # column is NOT NULL downstream, so this must fail loud rather than skip.
    with pytest.raises(ValueError):
        _norm([_row(amount_text="8,15")])


def test_bare_euro_symbol_defaults_to_eur_not_dropped():
    # The bare "\u20ac" case maps to EUR (not None), so the row survives.
    [rec] = _norm([_row(amount_text="8,15 \u20ac", description_text="6. Juni . Zahlung")])
    assert rec["currency"] == "EUR"


# --- synthetic-id collision (LOW #11) ----------------------------------------
def test_two_identical_codeless_rows_same_day_get_distinct_synthetic_ids():
    # Two code-LESS rows with identical economic content on the same day must NOT
    # collapse onto one synthetic id (which would drop one). The per-occurrence
    # index keeps them distinct.
    rows = [_row(id=""), _row(id="")]
    recs = _norm(rows)
    assert len(recs) == 2
    assert recs[0]["id"].startswith("pp-syn-")
    assert recs[1]["id"].startswith("pp-syn-")
    assert recs[0]["id"] != recs[1]["id"]


def test_codeless_synthetic_ids_are_stable_across_resyncs():
    # The doc-order occurrence index is deterministic, so the SAME two rows in the
    # same order produce the SAME pair of ids on a re-sync (idempotent ingest).
    rows = [_row(id=""), _row(id="")]
    a = [r["id"] for r in _norm(rows)]
    b = [r["id"] for r in _norm(rows)]
    assert a == b


def test_codeless_rows_differing_only_in_notes_get_distinct_ids():
    a = _norm([_row(id="", notes="ref A")])[0]
    b = _norm([_row(id="", notes="ref B")])[0]
    assert a["id"] != b["id"]
