#!/usr/bin/env python3
"""paypal_capture.py — locate the Transaktionscode source for the build.

Logs in (fixed fingerprint; PUSH=1 → PayPal-App approval), opens Aktivitäten,
then answers ONE build question: is the per-transaction Transaktionscode already
in the list-load (page HTML / an XHR) — so we scrape ONCE — or does it only show
on per-row EXPAND (so we capture the expand XHR / expanded DOM each row)?

  PP_USER=… [PW in env] HEADLESS=1 PUSH=1 \
    uv run --with cloakbrowser --with playwright python gate/paypal_capture.py
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
    sys.exit("cloakbrowser missing — run via uv run --with cloakbrowser --with playwright")

BASE = "https://www.paypal.com"
HERE = os.path.dirname(__file__)
PROFILE = os.path.abspath(os.path.join(HERE, "..", "tmp", "paypal-profile"))
HTML = os.path.abspath(os.path.join(HERE, "..", "tmp", "paypal-activity.html"))
SHOT = os.path.abspath(os.path.join(HERE, "..", "tmp", "paypal-capture.png"))
SCHEMA = os.path.abspath(os.path.join(HERE, "..", "tmp", "paypal-activities-schema.json"))

# Transaktionscode shape: 17 chars, mixed letters+digits (e.g. 6N525348VK696663J).
TX = re.compile(r"[0-9A-Z]{17}")
def codes(text):
    return {c for c in TX.findall(text or "") if any(ch.isdigit() for ch in c) and any(ch.isalpha() for ch in c)}

def redact(o, d=0):
    """Structure with leaf VALUES replaced by their type — safe to share."""
    if d > 6:
        return "…"
    if isinstance(o, dict):
        return {k: redact(v, d + 1) for k, v in list(o.items())[:60]}
    if isinstance(o, list):
        return [redact(o[0], d + 1), "…(+%d)" % (len(o) - 1)] if o else []
    return type(o).__name__

def find_rows(obj):
    """Return (json_pointer, biggest_list_of_dicts) — the transaction rows."""
    best = [None, None]
    def walk(x, p):
        if isinstance(x, dict):
            for k, v in x.items():
                walk(v, "%s.%s" % (p, k))
        elif isinstance(x, list):
            ds = [e for e in x if isinstance(e, dict)]
            if ds and (best[1] is None or len(ds) > len(best[1])):
                best[0], best[1] = p, ds
            for i, e in enumerate(x):
                walk(e, "%s[%d]" % (p, i))
    walk(obj, "$")
    return best[0], best[1]

user = os.environ.get("PP_USER")
pw = os.environ.get("PW")
if not user or not pw:
    sys.exit("set PP_USER and PW in the environment")

resp_log = []  # (method, status, content_type, url, text)
def on_response(r):
    try:
        if not r.url.startswith(BASE):
            return
        ct = r.headers.get("content-type", "").split(";")[0]
        keep = ("json" in ct) or any(s in r.url for s in ("activit", "transaction", "graphql", "/api"))
        text = r.text() if keep else ""
        resp_log.append((r.request.method, r.status, ct, r.url, text))
    except Exception:
        pass

fp = os.environ.get("PP_FINGERPRINT", "61803")
ctx = launch_persistent_context(
    PROFILE, headless=os.environ.get("HEADLESS") == "1",
    stealth_args=False, args=["--no-sandbox", f"--fingerprint={fp}", "--fingerprint-platform=windows"],
)
page = ctx.pages[0] if ctx.pages else ctx.new_page()
page.set_default_timeout(15000)
page.on("response", on_response)

# --- login -------------------------------------------------------------------
print("→ login…")
page.goto(BASE + "/signin", wait_until="domcontentloaded")
page.wait_for_timeout(3000)
try:
    e = page.locator("#email")
    if e.count() == 0:
        e = page.locator("input[type='email']").first
    e.fill(user, timeout=8000)
    p = page.locator("#password")
    if p.count() == 0 or not p.first.is_visible():
        try:
            nx = page.locator("#btnNext")
            if nx.count() == 0:
                nx = page.get_by_role("button", name=re.compile("Next|Weiter", re.I))
            nx.first.click(timeout=8000)
            page.wait_for_timeout(2000)
        except Exception:
            pass
        p = page.locator("#password")
    p.first.fill(pw, timeout=8000)
    b = page.locator("#btnLogin")
    if b.count() == 0:
        b = page.get_by_role("button", name=re.compile("Log ?In|Einloggen|Anmelden", re.I))
    b.first.click(timeout=8000)
except Exception as ex:
    print(f"  login fill incomplete: {type(ex).__name__}")

# push step-up — poll up to 30s for the step-up page, then auto-trigger the
# PayPal-App push so the user only has to tap their phone (no clicking in-window).
_end = time.time() + 30
_triggered = False
while time.time() < _end and not _triggered and "/myaccount" not in page.url:
    try:
        if "/authflow" in page.url or page.get_by_text("Bestätigen Sie jetzt Ihre Identität", exact=False).count() > 0:
            try:
                page.get_by_text("Verwenden Sie die PayPal-App", exact=False).first.click(timeout=3000)
            except Exception:
                pass
            w = page.get_by_role("button", name=re.compile("Weiter|Continue", re.I))
            if w.count() == 0:
                w = page.get_by_text("Weiter", exact=False)
            w.first.click(timeout=4000)
            _triggered = True
            print("→ STEP-UP: PayPal-App push sent — APPROVE IT ON YOUR PHONE now.")
    except Exception:
        pass
    page.wait_for_timeout(1500)

def logged_in():
    return "/myaccount" in page.url

dl = time.time() + int(os.environ.get("LOGIN_WAIT", "120"))
while time.time() < dl and not logged_in():
    page.wait_for_timeout(1000)
print(f"→ logged_in: {logged_in()}")
if not logged_in():
    print(f"  final_url: {urlsplit(page.url).path}")
    try:
        page.screenshot(path=SHOT, full_page=True)
    except Exception:
        pass
    ctx.close()
    sys.exit("login failed (captcha or push not approved) — see tmp/paypal-capture.png")

# --- activities --------------------------------------------------------------
end = dt.date.today()
start = end - dt.timedelta(days=365)
page.goto(f"{BASE}/myaccount/activities?start_date={start.isoformat()}&end_date={end.isoformat()}",
          wait_until="domcontentloaded")
page.wait_for_timeout(8000)
try:
    page.mouse.wheel(0, 3000)
    page.wait_for_timeout(2000)
except Exception:
    pass

# txcodes in the COLLAPSED list-load (page HTML + captured responses)
try:
    html = page.content()
except Exception:
    html = ""
try:
    open(HTML, "w", encoding="utf-8").write(html)
except Exception:
    pass
html_codes = codes(html)
resp_codes = {}
for m, s, ct, u, t in resp_log:
    c = codes(t)
    if c:
        path = urlsplit(u).path
        resp_codes[path] = resp_codes.get(path, 0) + len(c)

# --- DUMP the /myaccount/activities row SCHEMA (keys + types, NO values) ------
schema = None
for m, s, ct, u, t in resp_log:
    p = urlsplit(u).path
    if "/myaccount/activities" not in p or "extendSession" in p or "/inline/" in p or not t:
        continue
    try:
        body = json.loads(t)
    except Exception:
        continue
    ptr, rows = find_rows(body)
    if rows and (schema is None or len(rows) > schema["row_count"]):
        schema = {
            "endpoint": p,
            "rows_pointer": ptr,
            "row_count": len(rows),
            "row_keys": sorted(rows[0].keys()),
            "row_structure_types": redact(rows[0]),
        }
if schema:
    try:
        with open(SCHEMA, "w", encoding="utf-8") as f:
            json.dump(schema, f, indent=2, ensure_ascii=False)
    except Exception:
        pass
    print("\n--- ACTIVITIES ROW SCHEMA (keys + types, no values) ---")
    print(json.dumps(schema, indent=2, ensure_ascii=False))
else:
    print("\n--- ACTIVITIES JSON not parsed as rows (inspect resp_log paths) ---")

# --- expand the first transaction -------------------------------------------
n_before = len(resp_log)
expanded = False
for sel in ["[data-testid*='activityItem']", "[data-testid*='transaction']",
            "[data-testid*='ActivityItem']", "div[role='button']", "li"]:
    try:
        loc = page.locator(sel)
        if loc.count():
            loc.first.click(timeout=5000)
            expanded = True
            print(f"→ expanded first row via {sel!r}")
            break
    except Exception:
        continue
page.wait_for_timeout(5000)
expand_endpoints = {}
for m, s, ct, u, t in resp_log[n_before:]:
    expand_endpoints[urlsplit(u).path] = (s, ct, len(codes(t)))
try:
    html_after = page.content()
except Exception:
    html_after = ""
html_codes_after = codes(html_after)

print("\n================ SAFE TO SHARE ================")
print(f"  logged_in:                    {logged_in()}")
print(f"  txcodes_in_list_HTML:         {len(html_codes)}")
print(f"  txcodes_in_responses(by path):{resp_codes}")
print(f"  expanded_row:                 {expanded}")
print(f"  txcodes_in_HTML_after_expand: {len(html_codes_after)}")
print("  endpoints_fired_on_expand:")
for p, (s, ct, nc) in expand_endpoints.items():
    print(f"     {p}  [{s} {ct}]  txcodes={nc}")
print("\n  VERDICT:")
if len(html_codes) >= 5 or any(v >= 5 for v in resp_codes.values()):
    print("  → Transaktionscode is in the LIST LOAD → scrape ONCE, no per-row expand. ✅")
elif expanded and (len(html_codes_after) > len(html_codes) or any(nc > 0 for _, _, nc in expand_endpoints.values())):
    print("  → Transaktionscode only on EXPAND → capture the expand XHR / expanded DOM per row.")
else:
    print("  → Inconclusive — inspect tmp/paypal-activity.html (search for a 17-char code).")
print(f"  html saved: {HTML}")
ctx.close()
