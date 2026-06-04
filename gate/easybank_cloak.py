#!/usr/bin/env python3
"""
easybank_cloak.py — CloakBrowser feasibility gate for banking.easybank.de.

Launches a real (stealth) Chromium via CloakBrowser with a PERSISTENT profile
(the trusted-device store), logs in, and reads balance + 30-day transactions by
capturing the JSON the bank's own Angular app fetches (RetailLanding /
AccountTransactionHistory) — no brittle DOM scraping for the actual data.

Why a real browser: easybank runs JS device-fingerprinting (crashninja) and
relies on a trusted-device cookie. A real browser reproduces both and, via the
persistent profile, becomes a returning trusted device → no repeated mTAN.

First run downloads the CloakBrowser Chromium (~200MB) and may prompt for a
one-time mTAN. Subsequent runs reuse the profile → should be password-only.

Credentials from env (never hardcoded/printed):
  EASYBANK_USER  (default: moguls753)
  PW             (REQUIRED)

Run HEADED on your desktop (most human-like, and same IP as your normal logins):
  PW='...' uv run --with cloakbrowser --with playwright python gate/easybank_cloak.py

The browser opens VISIBLY. If auto-fill misses a field, just log in by hand in
that window — the gate waits and then reads the data either way. On a fresh
Arch box you may first need:  playwright install-deps chromium
"""

import os
import sys
import time

try:
    from cloakbrowser import launch_persistent_context
except ImportError:
    sys.exit("cloakbrowser missing — run via:  uv run --with cloakbrowser --with playwright python gate/easybank_cloak.py")

BASE = "https://banking.easybank.de"
PROFILE = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "tmp", "easybank-profile"))


def find_first(obj, key):
    """Depth-first search for the first non-null value stored under `key`."""
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


def find_account(obj):
    """The account/card object: a CurrentBalance plus an account identifier."""
    if isinstance(obj, dict):
        if "CurrentBalance" in obj and any(k in obj for k in ("AccountType", "IBAN", "FullNumber", "Number")):
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


def main():
    user = os.environ.get("EASYBANK_USER", "moguls753")
    pw = os.environ.get("PW")
    if not pw:
        sys.exit("Set PW (the password) in the environment.")
    os.makedirs(PROFILE, exist_ok=True)

    captured = {"landing": None, "history": None}

    def on_response(resp):
        url = resp.url
        try:
            if "/services/flow/RetailLanding" in url:
                captured["landing"] = resp.json()
            elif "/services/flow/AccountTransactionHistory" in url:
                captured["history"] = resp.json()
        except Exception:
            pass

    ctx = launch_persistent_context(PROFILE, headless=False)
    page = ctx.pages[0] if ctx.pages else ctx.new_page()
    page.on("response", on_response)

    print("→ opening login page…")
    page.goto(BASE + "/Login", wait_until="domcontentloaded")
    page.wait_for_timeout(3000)

    # Best-effort auto-fill of the Angular-rendered login form.
    try:
        u = page.get_by_label("Benutzername")
        if u.count() == 0:
            u = page.locator("input[type='text'], input:not([type])").first
        u.fill(user, timeout=8000)
        p = page.get_by_label("Passwort")
        if p.count() == 0:
            p = page.locator("input[type='password']").first
        p.fill(pw, timeout=8000)
        page.get_by_role("button", name="Anmelden").click(timeout=8000)
        print("→ submitted credentials automatically")
    except Exception as e:
        print(f"→ auto-fill incomplete ({type(e).__name__}); log in MANUALLY in the open window.")

    print("→ if an mTAN / SMS prompt appears, enter the code IN THE BROWSER window.")
    print("→ waiting for dashboard (up to 180s)…")
    deadline = time.time() + 180
    while time.time() < deadline and captured["landing"] is None:
        page.wait_for_timeout(1000)

    logged_in = captured["landing"] is not None
    print(f"→ logged in (RetailLanding seen): {logged_in}")

    # Navigate to the transaction list to trigger AccountTransactionHistory.
    if logged_in and captured["history"] is None:
        try:
            page.get_by_text("Alle Umsätze").first.click(timeout=8000)
        except Exception:
            try:
                page.goto(BASE + "/accounttransactionhistory/start", wait_until="domcontentloaded")
            except Exception:
                pass
        d2 = time.time() + 30
        while time.time() < d2 and captured["history"] is None:
            page.wait_for_timeout(1000)

    landing, hist = captured["landing"], captured["history"]
    account = find_account(landing) or find_account(hist)
    bal = find_first(account, "CurrentBalance") if account else find_first(landing, "CurrentBalance")
    txs = find_first(hist, "Transactions") if hist else None

    print("\n================ SAFE TO SHARE (no amounts / names) ================")
    print(f"  logged_in: {logged_in}")
    print(f"  retail_landing_captured: {landing is not None}")
    print(f"  transaction_history_captured: {hist is not None}")
    print(f"  account_found: {account is not None}")
    print(f"  balance_found: {bal is not None}")
    print(f"  transactions_returned: {len(txs) if isinstance(txs, list) else None}")
    print(f"  history_OTPRequired: {find_first(hist, 'OTPRequired')!r}")

    print("\n---------------- LOCAL ONLY (your data — no need to paste) ----------")
    if isinstance(bal, dict):
        print(f"  Saldo (CurrentBalance): {bal.get('Value')} {find_first(bal, 'Code') or ''}")
    else:
        print("  Saldo: not found (see statuses above)")

    print("\n(profile saved to tmp/easybank-profile — a second run should skip the mTAN)")
    try:
        input("\nPress Enter to close the browser… ")
    except EOFError:
        pass
    ctx.close()


if __name__ == "__main__":
    main()
