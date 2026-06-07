"""PayPal scraper sidecar.

A small FastAPI service that drives the personal PayPal web UI (paypal.com)
through a real, stealth Chromium (CloakBrowser) and DOM-scrapes the activity list
the page server-renders. It is meant to run network-isolated behind an
allowlisting egress proxy — see paypal-scraper/README.md.

Personal PayPal accounts cannot obtain live REST API credentials, so — like the
easybank sidecar — this drives the bank's own web UI as the user. Login surfaces
a device step-up (a PayPal-app push approved out-of-band on the phone), so this is
MANUAL sync only: one blocking /sync request while the user is present to approve.
"""
