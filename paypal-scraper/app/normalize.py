"""Pure mapping from scraped PayPal activity rows to the /sync contract.

This module imports NOTHING from cloakbrowser/playwright on purpose (mirrors
easybank-scraper/app/normalize.py): the normalization is the part with real
logic and edge cases, so it must be unit-testable without a browser (see
tests/test_normalize.py). app.paypal does all the DOM work and hands the raw
scraped row dicts here.

A scraped row (what app.paypal.scrape emits per `trans_overview_root_container`)
is a flat dict of strings, e.g.:

    {
        "id": "55X63072JY995300U",       # from the row class, may be "" if absent
        "merchant": "eBay S.a.r.l.",      # counterparty_name text
        "amount_text": "−8,15 €",  # raw transaction_amount text
        "description_text": "6. Juni . Zahlung",  # raw transaction_description
        "notes": "\"Bestellnummer : ...\"",       # optional transaction-notes
    }

We turn that into the wire records EasyBank::Ingest already understands:

    {id, merchant, description, amount, currency, booking_date, is_pending}

Key decisions are pinned per PAYPAL_SCRAPER_PLAN.md §6 + §10 (which OVERRIDE §3).
"""

from __future__ import annotations

import hashlib
import re
from datetime import date
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation

# --- date parsing ------------------------------------------------------------
# German month names, full and abbreviated (PayPal prints "Juni", "Apr.", "März",
# "Dez."). Keys are lowercased and stripped of a trailing ".".
_MONTHS: dict[str, int] = {
    "januar": 1, "jan": 1,
    "februar": 2, "feb": 2,
    "märz": 3, "maerz": 3, "mär": 3, "mrz": 3,
    "april": 4, "apr": 4,
    "mai": 5,
    "juni": 6, "jun": 6,
    "juli": 7, "jul": 7,
    "august": 8, "aug": 8,
    "september": 9, "sep": 9, "sept": 9,
    "oktober": 10, "okt": 10,
    "november": 11, "nov": 11,
    "dezember": 12, "dez": 12,
}

# "6. Juni", "29. Apr.", "31. März" — day-dot, month name (maybe trailing ".").
_DAY_MONTH = re.compile(r"^\s*(\d{1,2})\.\s*([A-Za-zÄÖÜäöüß]+)\.?\s*$")

# A month-header that carries a year, e.g. "Mai 2026" / "Apr. 2026". Status /
# relative headers ("Abgeschlossen", "Diese Woche") are NOT this shape and are
# skipped by the year-carry walk (§10.2).
_MONTH_YEAR = re.compile(r"^\s*([A-Za-zÄÖÜäöüß]+)\.?\s+(\d{4})\s*$")

# Money: a German-locale figure with optional thousands dots, e.g. "8,15",
# "1.234,56", "5.000" (zero-decimal grouped, e.g. JPY), "1.234". The sign
# (U+2212/U+002D) and currency are handled separately. Alternatives are ordered
# longest-first so a grouped integer ("1.234") matches the grouped form and not
# a bare "1" (which would then strip the dot to 1 — 1000x too small).
_DECIMAL = re.compile(
    r"\d{1,3}(?:\.\d{3})*,\d{2}"  # grouped + comma-decimal: 1.234,56
    r"|\d+,\d{2}"                 # plain comma-decimal: 8,15
    r"|\d{1,3}(?:\.\d{3})+"       # grouped integer, no decimal: 5.000 / 1.234
    r"|\d+"                       # bare integer: 79
)

# A trailing ISO-4217 token, e.g. the "USD" in "−10,60 $ USD".
_ISO_TOKEN = re.compile(r"\b([A-Z]{3})\b")

# Currency symbol -> ISO-4217. Bare "€" with no trailing token => EUR.
_SYMBOL_ISO = {
    "€": "EUR",
    "$": "USD",
    "£": "GBP",
    "¥": "JPY",
    "CHF": "CHF",
}

_CENTS = Decimal("0.01")


def _normalize_minus(text: str) -> str:
    """Map the typographic minus U+2212 and the en-dash U+2013 to ASCII '-', and
    the non-breaking space U+00A0 / narrow-nbsp U+202F to a plain space."""
    return (
        text.replace("−", "-")
        .replace("–", "-")
        .replace(" ", " ")
        .replace(" ", " ")
    )


def parse_amount(amount_text: str) -> Decimal | None:
    """Signed Decimal from a PayPal amount string, e.g. '−8,15 €'
    -> Decimal('-8.15'); '79,00 €' -> Decimal('79.00');
    '−10,60 $ USD' -> Decimal('-10.60'). Strips German thousands dots,
    treats the comma as the decimal separator. Returns None if unparseable (the
    caller fails loud — a None amount silently skips the row downstream)."""
    if not amount_text:
        return None
    cleaned = _normalize_minus(amount_text)
    negative = "-" in cleaned
    m = _DECIMAL.search(cleaned)
    if not m:
        return None
    raw = m.group(0).replace(".", "").replace(",", ".")
    try:
        value = Decimal(raw).quantize(_CENTS, rounding=ROUND_HALF_UP)
    except (InvalidOperation, ValueError):
        return None
    if negative:
        value = -value
    return value


def parse_currency(amount_text: str) -> str | None:
    """ISO-4217 currency from a PayPal amount string. Prefer an explicit trailing
    ISO token ('−10,60 $ USD' -> 'USD'); else map the symbol ('−8,15 €'
    -> 'EUR'). Returns None if neither is present."""
    if not amount_text:
        return None
    cleaned = _normalize_minus(amount_text)
    iso = _ISO_TOKEN.search(cleaned)
    if iso:
        return iso.group(1)
    for symbol, code in _SYMBOL_ISO.items():
        if symbol in cleaned:
            return code
    return None


def parse_balance(balance_text: str) -> dict | None:
    """Parse a PayPal-Guthaben card fragment into the /sync balance contract.

    Reuses parse_amount + parse_currency (the same U+2212/U+00A0 + German-locale
    -> signed Decimal and symbol/ISO-token -> ISO-4217 logic the activity amounts
    use), so the card's "0,00 €" / "1.234,56 €" / "−5,00 $ USD" parse identically.

    Returns ``{"amount": "<decimal string>", "currency": "<ISO>"}`` (amount is the
    2dp Decimal string, e.g. "0.00"), or None if no amount/currency can be found
    in the fragment. Caller swallows a None (the balance is non-critical)."""
    if not balance_text:
        return None
    amount = parse_amount(balance_text)
    currency = parse_currency(balance_text)
    if amount is None or currency is None:
        return None
    return {"amount": str(amount), "currency": currency}


def split_description(description_text: str) -> tuple[str, str]:
    """Split the fused 'date . type' string on ' . ' (space-dot-space), NOT the
    abbreviation dot in 'Apr.'/'Dez.' (§10.1). Returns (date_part, type_part).

    '6. Juni . Zahlung'                     -> ('6. Juni', 'Zahlung')
    '31. März . Zahlung im Einzugsverfahren'-> ('31. März', 'Zahlung im Einzugsverfahren')
    A string without the separator returns ('', text) so the type still carries."""
    if not description_text:
        return "", ""
    parts = description_text.split(" . ", 1)
    if len(parts) == 2:
        return parts[0].strip(), parts[1].strip()
    return "", description_text.strip()


def parse_day_month(date_part: str) -> tuple[int, int] | None:
    """(month, day) from '6. Juni' / '29. Apr.' / '31. März'. None if unparseable."""
    m = _DAY_MONTH.match(date_part)
    if not m:
        return None
    day = int(m.group(1))
    month = _MONTHS.get(m.group(2).lower().rstrip("."))
    if month is None or not (1 <= day <= 31):
        return None
    return month, day


def parse_header_year(header_text: str) -> int | None:
    """Year from a month-header like 'Mai 2026' / 'Apr. 2026'. None for status /
    relative headers ('Abgeschlossen', 'Diese Woche') which carry no year."""
    m = _MONTH_YEAR.match(header_text or "")
    if not m:
        return None
    if m.group(1).lower().rstrip(".") not in _MONTHS:
        return None
    return int(m.group(2))


def _resolve_year(month: int, day: int, carry_year: int | None, today: date) -> int:
    """Pick the year for a (month, day). If a month-header carried one, use it;
    else derive from today and, if the resulting date is in the FUTURE, step back
    a year (the Dec->Jan boundary guard, §10.2)."""
    if carry_year is not None:
        return carry_year
    year = today.year
    try:
        if date(year, month, day) > today:
            year -= 1
    except ValueError:
        # e.g. 29 Feb in a non-leap year — keep the candidate year; the sanity
        # bound below will reject a nonsensical date.
        pass
    return year


def _synthetic_id(rec: dict, occurrence: int) -> str:
    """Deterministic id for a row PayPal gave no Transaktionscode (the row class
    id) — mirrors easybank's _synthetic_id. Stable across syncs (so re-imports
    dedupe) and identical for true duplicates; derived from economic content.
    Never blank (a null/blank id fails the Rails presence/unique constraint and
    would abort the whole ingest batch).

    ``occurrence`` is a per-(date,amount,merchant,type) index folded into the
    basis so that two or more code-LESS rows with identical economic content on
    the same day don't collapse onto one synthetic id (which would drop all but
    one). The walk visits rows in stable document order, so the same real-world
    row keeps the same occurrence index across re-syncs."""
    basis = "|".join(
        str(rec.get(k) or "")
        for k in ("booking_date", "amount", "currency", "merchant", "type", "notes")
    )
    basis += f"|#{occurrence}"
    return "pp-syn-" + hashlib.sha1(basis.encode("utf-8")).hexdigest()[:20]


def normalize(rows: list[dict], date_from: str, date_to: str, *, today: date | None = None) -> list[dict]:
    """Turn the scraped rows (document order, newest first) into wire records.

    A row dict may carry a header marker instead of a transaction: a row with a
    truthy ``header`` key is a section header whose ``header`` text is fed to the
    SINGLE document-order year-carry walk (§10.2). Only ``Monat JJJJ`` headers
    set the carry year; status/relative headers leave it untouched.

    Each emitted record has EXACTLY these wire keys (the contract EasyBank::Ingest
    reads):
        id           str   never blank (Transaktionscode else _synthetic_id)
        merchant     str|None
        description  str|None  (the transaction type, e.g. "Zahlung")
        amount       str       signed 2dp Decimal string, NOT NULL
        currency     str|None  ISO-4217 (col limit:3)
        booking_date str       'YYYY-MM-DD', within [date_from, date_to]
        is_pending   bool      always False (booked-only, §10.4)

    Fail-loud: an amount or a date that can't be parsed/resolved raises ValueError
    rather than emitting a blank that would silently skip the row downstream.
    """
    today = today or date.today()
    lo = date.fromisoformat(date_from)
    hi = date.fromisoformat(date_to)
    carry_year: int | None = None
    out: list[dict] = []
    # Per-(date,amount,merchant,type) occurrence counter so ≥2 identical code-LESS
    # rows on the same day get distinct synthetic ids (see _synthetic_id).
    syn_seen: dict[tuple, int] = {}

    for row in rows:
        header = row.get("header")
        if header:
            year = parse_header_year(str(header))
            if year is not None:
                carry_year = year
            # status/relative header (Abgeschlossen, Diese Woche) -> leave carry
            continue

        amount_text = row.get("amount_text") or ""
        amount = parse_amount(amount_text)
        if amount is None:
            raise ValueError(f"unparseable amount: {amount_text!r}")
        currency = parse_currency(amount_text)
        # currency is NOT NULL downstream (BankConnection account currency, col
        # limit:3); a None here would silently skip the row under the per-row
        # ingest rescue. Fail loud instead (the bare-"€" case already maps to EUR
        # via _SYMBOL_ISO, so this only fires on a genuinely unknown token).
        if currency is None:
            raise ValueError(f"unparseable currency: {amount_text!r}")

        date_part, type_part = split_description(row.get("description_text") or "")
        dm = parse_day_month(date_part)
        if dm is None:
            raise ValueError(f"unparseable date: {date_part!r}")
        month, day = dm
        year = _resolve_year(month, day, carry_year, today)
        try:
            booking = date(year, month, day)
        except ValueError as e:
            raise ValueError(f"invalid date {year}-{month}-{day}: {e}") from e

        # Sanity-bound: a wrong-year date parses cleanly, so the parse-error guard
        # alone misses it. Reject anything outside the queried window (§10.2).
        if not (lo <= booking <= hi):
            raise ValueError(
                f"booking_date {booking.isoformat()} outside queried window "
                f"[{date_from}, {date_to}]"
            )

        rec = {
            "id": (str(row.get("id")).strip() or None),
            "merchant": (row.get("merchant") or None),
            "description": (type_part or None),
            "amount": str(amount),
            "currency": currency,
            "booking_date": booking.isoformat(),
            "is_pending": False,
        }
        if rec["id"] is None:
            # transient keys feed _synthetic_id only
            rec["type"] = type_part or None
            rec["notes"] = (row.get("notes") or None)
            key = (rec["booking_date"], rec["amount"], rec["merchant"], rec["type"])
            occurrence = syn_seen.get(key, 0)
            syn_seen[key] = occurrence + 1
            rec["id"] = _synthetic_id(rec, occurrence)
            rec.pop("type")
            rec.pop("notes")
        out.append(rec)

    return out
