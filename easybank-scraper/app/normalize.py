"""Pure mapping from captured VeriChannel JSON to the /sync contract.

This module imports NOTHING from cloakbrowser/playwright on purpose: the
normalization is the part with real logic and edge cases, so it must be unit
testable without a browser (see tests/test_normalize.py). app.easybank does all
the browser work and hands the raw captured dicts here.

The two captured payloads:
  * RetailLanding              -> the account/card object (balance, IBAN, limits)
  * AccountTransactionHistory  -> the transaction rows

Both are VeriChannel envelopes that nest the useful data deep and inconsistently
(domestic vs. foreign cards differ), so we search by key rather than assume a
fixed path.
"""

from __future__ import annotations

from decimal import ROUND_HALF_UP, Decimal, InvalidOperation
from typing import Any

# Money is always rendered to 2 decimal places (cents). JSON parsing turns the
# bank's literals into floats, so "26.80" arrives as 26.8 and "418.39" can carry
# binary noise; quantizing gives Kontor a single, stable string representation.
_CENTS = Decimal("0.01")


# --- generic, value-free traversal (same helpers the gate proved out) --------
def find_first(obj: Any, key: str) -> Any:
    """Depth-first search for the first non-null value stored under ``key``."""
    if isinstance(obj, dict):
        if key in obj and obj[key] is not None:
            return obj[key]
        for v in obj.values():
            r = find_first(v, key)
            if r is not None:
                return r
    elif isinstance(obj, list):
        for v in obj:
            r = find_first(v, key)
            if r is not None:
                return r
    return None


def _first_of(obj: Any, *keys: str) -> Any:
    """First non-null value for any of ``keys`` (tried in order). Each key is
    searched fully before moving on, so the preferred field wins even when a
    fallback sits shallower in the tree."""
    for key in keys:
        r = find_first(obj, key)
        if r is not None:
            return r
    return None


def find_account(obj: Any) -> dict | None:
    """The account/card object: it carries a CurrentBalance plus an account
    identifier. Matches the gate's heuristic exactly."""
    if isinstance(obj, dict):
        if "CurrentBalance" in obj and any(
            k in obj for k in ("AccountType", "IBAN", "FullNumber", "Number")
        ):
            return obj
        for v in obj.values():
            r = find_account(v)
            if r:
                return r
    elif isinstance(obj, list):
        for v in obj:
            r = find_account(v)
            if r:
                return r
    return None


# --- money helpers -----------------------------------------------------------
def _money(node: Any) -> dict | None:
    """Map a VeriChannel money node ``{Value, Currency:{Code}}`` to
    ``{value, currency}``. ``value`` is a 2dp string computed via Decimal (never
    binary float math), keeping the node's own sign — correct for balances and
    limits; transaction magnitudes (which the bank sends UNSIGNED) are re-signed
    in _amounts. Returns None if there is no usable Value."""
    if not isinstance(node, dict):
        return None
    raw = node.get("Value")
    if raw is None:
        return None
    try:
        # str(raw) first so a JSON float like 26.8 becomes the literal "26.8"
        # (not its binary expansion) before we quantize to cents.
        value = str(Decimal(str(raw)).quantize(_CENTS, rounding=ROUND_HALF_UP))
    except (InvalidOperation, ValueError, TypeError):
        return None
    return {"value": value, "currency": find_first(node, "Code")}


def _sign(tx: dict) -> int:
    """Direction of a transaction. easybank sends transaction magnitudes UNSIGNED
    (a debit's Value is +26.80, not -26.80) and conveys the direction in
    TransactionNature ("Debit"/"Credit"). We apply that. If TransactionNature is
    ever missing we fall back to the sign the bank printed in its own formatted
    string (FormattedLocalAmount, e.g. "-26,80 €")."""
    nature = str(find_first(tx, "TransactionNature") or "").strip().lower()
    if nature == "credit":
        return 1
    if nature == "debit":
        return -1
    fmt = str(find_first(tx, "FormattedLocalAmount") or find_first(tx, "FormattedAmount") or "")
    return -1 if fmt.strip().startswith("-") else 1


def _amounts(tx: dict) -> dict:
    """Split a transaction's two money fields into the settled-EUR vs.
    original/foreign pair, applying the direction from _sign.

    SIGN: the bank returns transaction magnitudes UNSIGNED; the direction lives in
    TransactionNature, so we sign abs(Value) by it. abs() also guards against a
    future feed that one day signs the values itself (no double-negation).

    EUR vs. ORIGINAL:
      * LocalCurrencyAmount = the amount settled to the account, in EUR. THIS is
        the figure Kontor books as ``amount``.
      * Amount = the ORIGINAL amount in its own currency — equal to the EUR
        figure for a domestic purchase; the foreign value for a foreign one.
    """
    local = _money(find_first(tx, "LocalCurrencyAmount"))
    original = _money(find_first(tx, "Amount"))

    # A robust fallback: if a row only ever carries one money node, treat it as
    # the settled EUR figure so ``amount`` is never empty.
    if local is None and original is not None:
        local = original
    if original is None and local is not None:
        original = local

    sign = _sign(tx)

    def _apply(m: dict | None) -> dict | None:
        if m is None:
            return None
        v = (Decimal(m["value"]).copy_abs() * sign).quantize(_CENTS, rounding=ROUND_HALF_UP)
        return {"value": str(v), "currency": m["currency"]}

    local, original = _apply(local), _apply(original)
    out: dict = {"amount": None, "currency": None, "original_amount": None, "original_currency": None}
    if local is not None:
        out["amount"] = local["value"]
        out["currency"] = local["currency"]
    if original is not None:
        out["original_amount"] = original["value"]
        out["original_currency"] = original["currency"]
    return out


# --- transactions ------------------------------------------------------------
def _collect_transactions(history: Any) -> list[dict]:
    """Gather the raw transaction rows from the AccountTransactionHistory
    envelope. They live under ``Item.InitialCallResponses[*].Response.Item.
    Transactions[]``, but capturing a "load more" page yields a slightly
    different envelope, so we just collect every ``Transactions`` list found and
    flatten them in document order."""
    rows: list[dict] = []

    def walk(node: Any) -> None:
        if isinstance(node, dict):
            txs = node.get("Transactions")
            if isinstance(txs, list):
                rows.extend(t for t in txs if isinstance(t, dict))
            for v in node.values():
                if v is not txs:  # don't descend back into the list we just took
                    walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(history)
    return rows


def _merchant(tx: dict) -> Any:
    """Merchant name, which sits either flat (MerchantName) or nested
    (MerchantData.Name) depending on the transaction kind."""
    flat = find_first(tx, "MerchantName")
    if flat is not None:
        return flat
    data = find_first(tx, "MerchantData")
    return find_first(data, "Name") if data is not None else None


def _date(value: Any) -> str | None:
    """A YYYY-MM-DD date from a VeriChannel datetime string, or None for the .NET
    min-date sentinel (``0001-01-01``), empty, or unparseable values. The bank
    leaves BookingDate as the min-date until a row is actually booked, so callers
    fall back across several date fields."""
    if not isinstance(value, str) or not value or value.startswith("0001-01-01"):
        return None
    d = value.split("T", 1)[0]
    return d if len(d) == 10 and d[4] == "-" and d[7] == "-" else None


def _first_date(tx: dict, *keys: str) -> str | None:
    for k in keys:
        d = _date(find_first(tx, k))
        if d:
            return d
    return None


def _normalize_tx(tx: dict) -> dict:
    amts = _amounts(tx)
    # No FX rate on domestic rows (the bank sends 0.0 there, which is misleading).
    xr = find_first(tx, "ExchangeRate")
    same_currency = amts["currency"] is not None and amts["currency"] == amts["original_currency"]
    out = {
        # Stable id: the bank's InternalID, falling back to the printed
        # ReferenceNumber when (e.g. on pending rows) it is absent.
        "id": _first_of(tx, "InternalID", "ReferenceNumber"),
        # BookingDate is the min-date until a row is booked, so fall back to the
        # posting/value/transaction date the user actually sees. Always a date.
        "booking_date": _first_date(tx, "BookingDate", "PostingDate", "ValueDate", "TransactionDate", "EffectiveDate"),
        "value_date": _first_date(tx, "ValueDate", "TransactionDate"),
        "description": find_first(tx, "Description"),
        "merchant": _merchant(tx),
        "mcc": find_first(tx, "MCCCode"),
        "exchange_rate": (xr if (xr and not same_currency) else None),
        # IsPending is unreliable on this card (always false); the booking STATUS
        # in TransactionType ("Pending" => vorgemerkt, vs "Unbilled"/"Billed") is
        # the real signal.
        "is_pending": str(find_first(tx, "TransactionType") or "").strip().lower() in ("pending", "vorgemerkt"),
        # Economic direction (Debit/Credit); the booking status is in is_pending.
        "type": find_first(tx, "TransactionNature"),
    }
    out.update(amts)
    # ``id`` may legitimately be numeric (InternalID) — coerce to str so the
    # Rails side has a consistent, hashable external id.
    if out["id"] is not None:
        out["id"] = str(out["id"])
    return out


# --- account + balance -------------------------------------------------------
def _normalize_account(account: dict | None) -> dict:
    if not isinstance(account, dict):
        return {
            "iban": None, "number": None, "name": None, "type": None,
            "credit_limit": None, "available_credit": None,
        }
    return {
        "iban": account.get("IBAN"),
        "number": _first_of(account, "Number", "FullNumber"),
        "name": _first_of(account, "AccountName", "ProductName"),
        "type": account.get("AccountType"),
        # Credit-card accounts expose a limit + remaining credit; current/giro
        # accounts simply won't have these keys, so they stay None.
        "credit_limit": _money(_first_of(account, "CurrentCreditLimit", "TotalCreditLimit")),
        "available_credit": _money(find_first(account, "AvailableCreditLimit")),
    }


def normalize(landing: Any, history: Any) -> dict:
    """Build the /sync response from the two captured payloads.

    Returns:
        balance      {value, currency} — the account's CurrentBalance.
        available     {value, currency} — spendable: AvailableCreditLimit on a
                      card (fallback AvailableBalanceInLocalCurrency on a giro).
        account       {iban, number, name, type, credit_limit, available_credit}
        transactions  list of normalized rows (see _normalize_tx).
        otp_required  whether the history call demanded an mTAN (longest-range
                      backfills do; the 30-day path must not).
    """
    account = find_account(landing) or find_account(history)

    balance = _money(find_first(account, "CurrentBalance") if account else find_first(landing, "CurrentBalance"))
    available = _money(_first_of(
        account if account is not None else landing,
        "AvailableCreditLimit",
        "AvailableBalanceInLocalCurrency",
    ))

    transactions = [_normalize_tx(t) for t in _collect_transactions(history)]

    return {
        "balance": balance,
        "available": available,
        "account": _normalize_account(account),
        "transactions": transactions,
        "otp_required": bool(find_first(history, "OTPRequired")),
    }
