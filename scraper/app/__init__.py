"""Trade Republic scraper sidecar.

A small FastAPI service that wraps `pytr` to do exactly two things:
pair a web session (2-step weblogin) and read the account's total balance
from a saved cookie session. It is meant to run network-isolated behind an
allowlisting egress proxy — see scraper/README and docs/trade-republic.md.
"""
