#!/usr/bin/env python3
"""paypal_reuse.py — does the persisted PayPal session survive across launches?

THE production sync-model test. Instead of logging in every sync (which triggers
PayPal's push step-up / reCAPTCHA), reuse the authenticated session cookie stored
in the persistent profile — just navigate straight to the activity page. If we're
still logged in, routine daily syncs need NO login → no captcha → no push, and we
only re-authenticate (rarely) when the session finally lapses.

Same profile + FIXED fingerprint as gate/paypal_cloak.py (so it's the same device).
  HEADLESS=1 uv run --with cloakbrowser --with playwright python gate/paypal_reuse.py
"""
import datetime as dt
import os
import sys
from urllib.parse import urlsplit

try:
    from cloakbrowser import launch_persistent_context
except ImportError:
    sys.exit("cloakbrowser missing — run via uv run --with cloakbrowser --with playwright")

BASE = "https://www.paypal.com"
HERE = os.path.dirname(__file__)
PROFILE = os.path.abspath(os.path.join(HERE, "..", "tmp", "paypal-profile"))
SHOT = os.path.abspath(os.path.join(HERE, "..", "tmp", "paypal-reuse.png"))

fp = os.environ.get("PP_FINGERPRINT", "61803")
ctx = launch_persistent_context(
    PROFILE,
    headless=os.environ.get("HEADLESS") == "1",
    stealth_args=False,
    args=["--no-sandbox", f"--fingerprint={fp}", "--fingerprint-platform=windows"],
)
page = ctx.pages[0] if ctx.pages else ctx.new_page()
page.set_default_timeout(15000)

end = dt.date.today()
start = end - dt.timedelta(days=365)
url = f"{BASE}/myaccount/activities?start_date={start.isoformat()}&end_date={end.isoformat()}"
print("→ REUSE: navigating STRAIGHT to activities — no login, relying on the session cookie…")
page.goto(url, wait_until="domcontentloaded")
page.wait_for_timeout(8000)

final = urlsplit(page.url).path
logged_in = "/myaccount" in page.url
try:
    title = page.title()
except Exception:
    title = "?"
try:
    page.screenshot(path=SHOT, full_page=True)
except Exception:
    pass

print("\n================ SAFE TO SHARE ================")
print(f"  session_reused (still logged in): {logged_in}")
print(f"  final_url_path:                   {final}")
print(f"  final_title:                      {title!r}")
print(f"  screenshot:                       {SHOT}")
print("  → True  = production model works: authenticate rarely, reuse session for daily syncs.")
print("  → False = session is short-lived; every sync re-logs-in and risks the captcha.")
ctx.close()
