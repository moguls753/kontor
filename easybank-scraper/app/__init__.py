"""easybank / Barclaycard DE scraper sidecar.

A small FastAPI service that drives banking.easybank.de's Angular (VeriChannel)
UI through a real, stealth Chromium (CloakBrowser) and reads balance + recent
transactions by capturing the JSON the bank's own app fetches (RetailLanding /
AccountTransactionHistory). It is meant to run network-isolated behind an
allowlisting egress proxy — see easybank-scraper/README.md.

Unlike the Trade Republic sidecar (which talks an API over a websocket and
stubs out playwright), this one needs a genuine headless browser: easybank runs
JS device fingerprinting and relies on a trusted-device cookie that only a real
browser + persistent profile reproduces.
"""
