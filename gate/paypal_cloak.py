#!/usr/bin/env python3
"""
paypal_cloak.py — CloakBrowser feasibility gate for paypal.com.

Port of gate/easybank_cloak.py. Settles the ONE load-bearing unknown before we
build a PayPal scraper sidecar: can a stealth Chromium reach the logged-in
PayPal activity data, and is there a STABLE per-transaction id to dedup on?
(The amount SIGN is already known from the activity UI: outgoing is negative.)

Why a real browser: PayPal runs aggressive bot/risk detection. CloakBrowser
presents a human-like fingerprint; the PERSISTENT profile becomes a trusted
device so repeat logins are smoother / password-only. TrueNAS is on your LAN, so
prod will log in from the SAME home IP as this desktop run — so this spike is
representative of production.

We do NOT scrape the DOM for data. We capture the JSON the PayPal SPA fetches
(by shape — any paypal.com response carrying a transaction-like array), so we
learn the real endpoint + field names for the build.

Credentials from env (never hardcoded / printed):
  PP_USER  (your PayPal email)    REQUIRED
  PW       (your PayPal password) REQUIRED

Run HEADED on your desktop (most human-like, same IP as your normal logins):
  PP_USER='you@example.com' PW='...' \
    uv run --with cloakbrowser --with playwright python gate/paypal_cloak.py

The browser opens VISIBLY. If auto-fill misses a field (or PayPal throws a
captcha / extra step), just finish logging in BY HAND in that window — the gate
waits, then reads the data either way. Fresh Arch box may first need:
  playwright install-deps chromium
"""

import datetime as dt
import json
import os
import re
import sys
import time
from urllib.parse import urlsplit

try:
    from cloakbrowser import launch_persistent_context
except ImportError:
    sys.exit("cloakbrowser missing — run via:  uv run --with cloakbrowser --with playwright python gate/paypal_cloak.py")

BASE = "https://www.paypal.com"
PROFILE = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "tmp", "paypal-profile"))
SAMPLE = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "tmp", "paypal-sample.json"))
SHOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "tmp", "paypal-fail.png"))
PAGETXT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "tmp", "paypal-page.txt"))
ENDPOINTS = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "tmp", "paypal-endpoints.txt"))

ID_RE = re.compile(r"(transaction.?id|activity.?id|^id$|txn|paymentid)", re.I)
AMOUNT_RE = re.compile(r"(amount|gross|net|value)", re.I)


def find_tx_arrays(obj, path="$"):
    """Yield (json_pointer, list_of_dicts) for every list whose elements look
    like transactions (carry an id-ish or amount-ish key). Depth-first."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield from find_tx_arrays(v, f"{path}.{k}")
    elif isinstance(obj, list):
        dicts = [x for x in obj if isinstance(x, dict)]
        if dicts:
            keys = set().union(*[d.keys() for d in dicts])
            if any(ID_RE.search(k) for k in keys) or any(AMOUNT_RE.search(k) for k in keys):
                yield path, dicts
        for i, v in enumerate(obj):
            yield from find_tx_arrays(v, f"{path}[{i}]")


def redact(obj, depth=0):
    """Structure with leaf VALUES replaced by their type — safe to paste."""
    if depth > 4:
        return "…"
    if isinstance(obj, dict):
        return {k: redact(v, depth + 1) for k, v in list(obj.items())[:40]}
    if isinstance(obj, list):
        return [redact(obj[0], depth + 1), f"…(+{len(obj) - 1} more)"] if obj else []
    return type(obj).__name__


def guess_id_field(dicts):
    """Pick the field that best serves as a stable dedup key: an id-ish key that
    is present + non-empty on every row AND unique across rows."""
    id_keys = [k for k in dicts[0].keys() if ID_RE.search(k)]
    for k in id_keys:
        vals = [d.get(k) for d in dicts]
        if all(v not in (None, "") for v in vals) and len(set(map(str, vals))) == len(vals):
            return k, True
    return (id_keys[0] if id_keys else None), False


def main():
    user = os.environ.get("PP_USER")
    pw = os.environ.get("PW")
    if not user or not pw:
        sys.exit("Set PP_USER (email) and PW (password) in the environment.")
    os.makedirs(PROFILE, exist_ok=True)

    captures = []   # list of (url, parsed_json)
    endpoints = []  # (method, status, content_type, path) for EVERY paypal response

    def on_response(resp):
        try:
            if not resp.url.startswith(BASE):
                return
            try:
                endpoints.append((resp.request.method, resp.status,
                                  resp.headers.get("content-type", "").split(";")[0],
                                  urlsplit(resp.url).path))
            except Exception:
                pass
            if "json" not in resp.headers.get("content-type", ""):
                # Some PayPal data endpoints omit/mislabel content-type — still try
                # JSON for activity/transaction/graphql/api-ish URLs.
                if not any(s in resp.url for s in ("activit", "transaction", "graphql", "/api")):
                    return
            captures.append((resp.url, resp.json()))
        except Exception:
            pass

    # FIXED fingerprint seed → a STABLE synthetic device across launches.
    # CloakBrowser otherwise randomizes --fingerprint every launch
    # (config.get_default_stealth_args: seed = random.randint(...)), so PayPal sees
    # a NEW device on every login and re-fires its step-up. We replicate the Linux
    # stealth args with a CONSTANT seed (stealth_args=False so ours isn't paired
    # with a random one) so cookie + device-trust can actually persist.
    fp = os.environ.get("PP_FINGERPRINT", "61803")
    ctx = launch_persistent_context(
        PROFILE,
        headless=os.environ.get("HEADLESS") == "1",
        stealth_args=False,
        args=["--no-sandbox", f"--fingerprint={fp}", "--fingerprint-platform=windows"],
    )
    page = ctx.pages[0] if ctx.pages else ctx.new_page()
    page.set_default_timeout(15000)
    page.on("response", on_response)

    print("→ opening PayPal sign-in…")
    page.goto(BASE + "/signin", wait_until="domcontentloaded")
    page.wait_for_timeout(3000)

    # Best-effort two-step login (email → Next → password → Log In). PayPal field
    # ids are historically stable; fall back to type/role so a relabel won't break.
    try:
        email = page.locator("#email")
        if email.count() == 0:
            email = page.locator("input[type='email'], input[name='login_email']").first
        email.fill(user, timeout=8000)

        pwf = page.locator("#password")
        if pwf.count() == 0 or not pwf.first.is_visible():
            try:
                nxt = page.locator("#btnNext")
                if nxt.count() == 0:
                    nxt = page.get_by_role("button", name=re.compile("Next|Weiter", re.I))
                nxt.first.click(timeout=8000)
                page.wait_for_timeout(2000)
            except Exception:
                pass
            pwf = page.locator("#password")
        pwf.first.fill(pw, timeout=8000)

        btn = page.locator("#btnLogin")
        if btn.count() == 0:
            btn = page.get_by_role("button", name=re.compile("Log ?In|Einloggen|Anmelden", re.I))
        btn.first.click(timeout=8000)
        print("→ submitted credentials automatically")
    except Exception as e:
        print(f"→ auto-fill incomplete ({type(e).__name__}); finish login MANUALLY in the open window.")

    # Bot/risk challenge detection (informational — never aborts).
    challenge = False
    try:
        if page.locator("iframe[src*='recaptcha'], iframe[title*='recaptcha']").count() > 0:
            challenge = True
        txt = (page.locator("body").inner_text(timeout=2000) or "").lower()
        if any(n in txt for n in ("captcha", "sicherheitsüberprüfung", "ungewöhnlich", "verify your", "roboter")):
            challenge = True
    except Exception:
        pass

    # PayPal device step-up: trigger the PayPal-App push (default, code-free) so
    # the user only taps "Yes" on their phone — no captcha, no code entry.
    try:
        page.wait_for_timeout(3000)
        step_up = ("/authflow" in page.url
                   or page.get_by_text("Bestätigen Sie jetzt Ihre Identität", exact=False).count() > 0)
        if step_up and os.environ.get("PUSH") == "1":
            try:
                page.get_by_text("Verwenden Sie die PayPal-App", exact=False).first.click(timeout=4000)
            except Exception:
                pass
            weiter = page.get_by_role("button", name=re.compile("Weiter|Continue", re.I))
            if weiter.count() == 0:
                weiter = page.get_by_text("Weiter", exact=False)
            weiter.first.click(timeout=6000)
            print("→ STEP-UP: sent a PayPal-App approval — TAP 'Ja, ich bin's' on your phone NOW.")
        elif step_up:
            print("→ STEP-UP PRESENT (device NOT trusted). Not pushing — set PUSH=1 to approve via app.")
        else:
            print("→ NO step-up — logged straight in on the trusted profile (password-only). ✓")
    except Exception as e:
        print(f"→ step-up handling skipped ({type(e).__name__})")

    print("→ if a captcha / extra verification appears, complete it IN THE BROWSER window.")
    print("→ waiting for login to land on /myaccount…")

    def logged_in():
        if "/myaccount" in page.url:
            return True
        try:
            return (page.get_by_text("AUSLOGGEN", exact=False).count() > 0
                    or page.get_by_text("Log Out", exact=False).count() > 0)
        except Exception:
            return False

    deadline = time.time() + int(os.environ.get("LOGIN_WAIT", "300"))
    while time.time() < deadline and not logged_in():
        try:
            if page.get_by_text("angemeldet bleiben", exact=False).count() > 0:
                page.get_by_role("button", name=re.compile("^(Ja|Yes)$", re.I)).first.click(timeout=3000)
        except Exception:
            pass
        page.wait_for_timeout(1000)
    is_in = logged_in()
    print(f"→ logged in: {is_in}")

    # Navigate to a wide activity window and CAPTURE the transactions fetch. The
    # React list lazy-loads, so poll for a transaction-SHAPED response (ignoring
    # the login-page country-list false positive) while scrolling to nudge it.
    def have_tx():
        for u, b in captures:
            if u.rstrip("/").endswith("load-resource"):
                continue
            for _p, _d in find_tx_arrays(b):
                return True
        return False

    if is_in:
        end = dt.date.today()
        start = end - dt.timedelta(days=365)
        url = f"{BASE}/myaccount/activities?start_date={start.isoformat()}&end_date={end.isoformat()}"
        print("→ opening activities (last 365 days)…")
        try:
            page.goto(url, wait_until="domcontentloaded")
        except Exception:
            pass
        d2 = time.time() + 35
        while time.time() < d2 and not have_tx():
            try:
                page.mouse.wheel(0, 4000)
            except Exception:
                pass
            page.wait_for_timeout(1500)
        page.wait_for_timeout(2000)

    # Snapshot the FINAL state (after the activities nav) so the screenshot shows
    # the activity page. Screenshot + page text are LOCAL-ONLY (tmp/, gitignored).
    final_path = urlsplit(page.url).path
    try:
        title = page.title()
    except Exception:
        title = "?"
    try:
        page.screenshot(path=SHOT, full_page=True)
    except Exception:
        pass
    try:
        with open(PAGETXT, "w", encoding="utf-8") as f:
            f.write(page.locator("body").inner_text(timeout=3000) or "")
    except Exception:
        pass
    try:
        with open(ENDPOINTS, "w", encoding="utf-8") as f:
            for m, s, ct, p in endpoints:
                f.write(f"{m}\t{s}\t{ct}\t{p}\n")
    except Exception:
        pass

    # Find the richest transaction-bearing JSON response.
    best = None  # (url, pointer, dicts)
    json_paths = []
    for url, body in captures:
        json_paths.append(urlsplit(url).path)
        if url.rstrip("/").endswith("load-resource"):
            continue  # login-page country dropdown — not transactions
        for pointer, dicts in find_tx_arrays(body):
            if best is None or len(dicts) > len(best[2]):
                best = (url, pointer, dicts)

    print("\n================ SAFE TO SHARE (no amounts / names) ================")
    print(f"  logged_in:           {is_in}")
    print(f"  bot_challenge_seen:  {challenge}")
    print(f"  final_url_path:      {final_path}")
    print(f"  final_page_title:    {title!r}")
    print(f"  screenshot:          {SHOT}")
    print(f"  json_endpoints_hit:  {sorted(set(json_paths))[:25]}")
    if best:
        url, pointer, dicts = best
        idk, unique = guess_id_field(dicts)
        print(f"  tx_endpoint_path:    {urlsplit(url).path}")
        print(f"  tx_json_pointer:     {pointer}")
        print(f"  tx_count:            {len(dicts)}")
        print(f"  sample_tx_keys:      {sorted(dicts[0].keys())}")
        print(f"  guessed_id_field:    {idk!r}  (present_in_all_and_unique={unique})")
        print("  sample_tx_STRUCTURE (types only, no values):")
        print("    " + json.dumps(redact(dicts[0]), indent=2, ensure_ascii=False).replace("\n", "\n    "))
        try:
            with open(SAMPLE, "w", encoding="utf-8") as f:
                json.dump({"endpoint": url, "pointer": pointer, "sample": dicts[0]}, f,
                          ensure_ascii=False, indent=2)
            print(f"\n  (full sample row written LOCAL-ONLY to {SAMPLE} — inspect/share selectively)")
        except Exception:
            pass
    else:
        print("  tx_endpoint_path:    <none found> — login may have failed, or the data loads")
        print("                       differently. Try the ⬇ CSV download by hand and tell me its columns.")

    print("\n(profile saved to tmp/paypal-profile — a second run should be smoother / password-only)")
    try:
        input("\nPress Enter to close the browser… ")
    except EOFError:
        pass
    ctx.close()


if __name__ == "__main__":
    main()
