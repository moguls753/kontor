#!/usr/bin/env python3
"""
easybank_login.py — feasibility GATE: can a pure HTTP client log into
banking.easybank.de and read balance + 30-day transactions WITHOUT a browser
and WITHOUT triggering mTAN?

Replicates the VeriChannel JSON flow observed in the DevTools HAR:
  GET  /Login                                            (cookies + XSRF-TOKEN)
  POST /services/flow/LoginTransaction                   (init flow, {})
  POST /services/flow/logintransaction/firstlevel/next   (UserName + Password)
  POST /call/flow/Login/AfterLogin                       (finalize)
  POST /services/flow/RetailLanding                      (dashboard -> balance)
  POST /services/flow/AccountTransactionHistory          (last 30 days -> tx)

Auth is cookie-based (.ASPXAUTH) + the Angular double-submit XSRF header
(X-XSRF-TOKEN echoes the non-HttpOnly XSRF-TOKEN cookie). No request signing.

The KEY thing this answers: the user's browser is a "remembered device", so it
logs in password-only. A fresh client has no device cookie — so this tells us
whether the bank then demands a one-time login-mTAN (which we'd handle with a
one-off pairing like Trade Republic, storing the device cookie) or lets us in.

Credentials come from the environment — nothing is hardcoded or printed:
  EASYBANK_USER  (default: moguls753)
  PW             (the password — REQUIRED)

Run (uv pulls httpx into an ephemeral env; nothing installed globally):
  PW='your-password' uv run --with "httpx[http2]" python gate/easybank_login.py

Output: a SAFE-TO-SHARE summary (statuses + enum strings, no amounts/names)
and a LOCAL-ONLY line (your balance, for your eyes — no need to paste it).
"""

import os
import sys

try:
    import httpx
except ImportError:
    sys.exit("httpx missing — run via:  uv run --with 'httpx[http2]' python gate/easybank_login.py")

BASE = "https://banking.easybank.de"
UA = "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"

# VeriChannel transaction-framework flags — all observed as false/0 in the HAR.
FLOW_DEFAULTS = {
    "SkipAuthenticationItem": False,
    "IsNotLoginTransaction": False,
    "SelectedApprovalRule": 0,
    "SelectedApprovalSubRule": 0,
    "DisableNonStp": False,
    "IsSourceFutureDated": False,
    "OpenCaseAndExecuteTransaction": False,
    "OpenConditionalCase": False,
    "OpenCaseAndNotExecute": False,
}


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
    """The account/card object: carries a CurrentBalance plus an account id."""
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


def post(client, path, body, label):
    headers = {"X-Requested-With": "XMLHttpRequest"}
    xsrf = client.cookies.get("XSRF-TOKEN")
    if xsrf:
        headers["X-XSRF-TOKEN"] = xsrf
    r = client.post(BASE + path, json=body, headers=headers)
    try:
        data = r.json()
    except Exception:
        data = None
    note = ""
    top = data.get("Result") if isinstance(data, dict) else None
    if isinstance(top, dict) and top.get("IsSuccess") is False:
        err = find_first(data, "Error") or {}
        note = f"  ERROR: {err.get('Code')!r} {err.get('DisplayMessage')!r}"
    elif data is None:
        note = f"  (non-JSON, {len(r.content)} bytes)"
    print(f"  [{label}] POST {path} -> {r.status_code}{note}")
    return r, data


def main():
    user = os.environ.get("EASYBANK_USER", "moguls753")
    pw = os.environ.get("PW")
    if not pw:
        sys.exit("Set PW (the password) in the environment.")

    s = {}
    bal = None
    with httpx.Client(http2=True, follow_redirects=True, timeout=30,
                      headers={"User-Agent": UA,
                               "Accept": "application/json, text/plain, */*"}) as client:
        r = client.get(BASE + "/Login")
        print(f"  [bootstrap] GET /Login -> {r.status_code}; XSRF cookie set: {bool(client.cookies.get('XSRF-TOKEN'))}")

        post(client, "/services/flow/LoginTransaction", {}, "init")

        cred = dict(FLOW_DEFAULTS, OTPPassword="", IsCaptchaRequired=False,
                    DefineLater=False, UserName=user, Password=pw)
        _, login = post(client, "/services/flow/logintransaction/firstlevel/next", cred, "login")
        resp = find_first(login, "Response") or {}
        s["LoginResult"] = resp.get("LoginResult")
        s["OTPRequirementReason"] = resp.get("OTPRequirementReason")
        s["NextFlowItemType"] = resp.get("NextFlowItemType")
        s["RemainingRetryCount"] = resp.get("RemainingRetryCount")
        print(f"     LoginResult={s['LoginResult']!r}  OTPReason={s['OTPRequirementReason']!r}  NextFlow={s['NextFlowItemType']!r}")

        after = dict(cred, Password=None,
                     UserID=find_first(login, "UserID"),
                     CustomerType=find_first(login, "CustomerType"),
                     LandingPage=find_first(login, "LandingPage"),
                     NeedCaptcha=find_first(login, "NeedCaptcha") or False,
                     DiscardPasswordHashCheck=find_first(login, "DiscardPasswordHashCheck") or False)
        post(client, "/call/flow/Login/AfterLogin", after, "afterlogin")

        _, landing = post(client, "/services/flow/RetailLanding", {}, "landing")
        account = find_account(landing)
        s["account_found"] = account is not None
        bal = find_first(account, "CurrentBalance") if account else find_first(landing, "CurrentBalance")
        s["balance_found"] = bal is not None

        if account:
            _, hist = post(client, "/services/flow/AccountTransactionHistory", {"Account": account}, "history")
            hresp = find_first(hist, "Response") or {}
            s["OTPRequired"] = hresp.get("OTPRequired")
            s["HasMore"] = hresp.get("HasMore")
            s["TotalRowCount"] = hresp.get("TotalRowCount")
            txs = find_first(hist, "Transactions")
            s["transactions_returned"] = len(txs) if isinstance(txs, list) else None

    print("\n================ SAFE TO SHARE (no amounts / names) ================")
    for k in ("LoginResult", "OTPRequirementReason", "NextFlowItemType", "RemainingRetryCount",
              "account_found", "balance_found", "OTPRequired", "HasMore",
              "TotalRowCount", "transactions_returned"):
        if k in s:
            print(f"  {k}: {s[k]!r}")

    print("\n---------------- LOCAL ONLY (your data — no need to paste) ----------")
    if isinstance(bal, dict):
        print(f"  Saldo (CurrentBalance): {bal.get('Value')} {find_first(bal, 'Code') or ''}")
    elif bal is not None:
        print(f"  Saldo: {bal}")
    else:
        print("  Saldo: not found (see statuses above)")

    ok = bool(s.get("LoginResult")) and s.get("balance_found") and s.get("OTPRequired") in (False, None)
    print("\nVERDICT:", "✅ password-only login worked, balance + tx readable, NO mTAN"
          if ok else "⚠️  not clean — check LoginResult / OTPRequirementReason above (likely device-mTAN on a fresh client)")


if __name__ == "__main__":
    main()
