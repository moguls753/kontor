"""Phase-1 egress audit — run INSIDE the tr-scraper container.

Proves the network isolation that justifies storing Trade Republic credentials:

  * Through the proxy: Trade Republic and *.awswaf.com are reachable, but any
    other host (google, example.com) is denied by squid policy.
  * Around the proxy: a direct connection (IPv4, IPv6, raw IP) has no route out.
  * Both HTTP stacks pytr uses (stdlib `requests` and `curl_cffi`) honour the
    proxy from the environment.

The squid access.log is the authoritative artifact for the policy decisions;
this script drives the attempts and reports what each client saw.

Usage:
  docker compose -f compose.scraper.yml cp gate/egress_audit.py tr-scraper:/tmp/
  docker compose -f compose.scraper.yml exec tr-scraper python /tmp/egress_audit.py
"""

import json
import os
import socket

import requests

try:
    from curl_cffi import requests as cffi
except Exception:  # pragma: no cover - curl_cffi is always present in the image
    cffi = None

PROXY = os.environ.get("HTTPS_PROXY", "")

# Hosts that the allowlist must permit (TR + the AWS WAF token host) and hosts
# it must deny. The awswaf host is synthetic — we only assert squid does not
# *policy-deny* it (a DNS/connect failure to a made-up host is fine; the live
# pairing exercises a real one).
ALLOW_HOSTS = ["https://app.traderepublic.com/login", "https://prod.token.awswaf.com/"]
DENY_HOSTS = ["https://www.google.com", "https://example.com"]


def _req_via_proxy(url: str) -> dict:
    try:
        r = requests.get(url, timeout=15)
        return {"result": "reached", "status": r.status_code}
    except requests.exceptions.ProxyError as e:
        return {"result": "proxy_blocked", "detail": str(e)[:200]}
    except Exception as e:
        return {"result": "error", "detail": f"{type(e).__name__}: {str(e)[:160]}"}


def _cffi_via_proxy(url: str) -> dict:
    if cffi is None:
        return {"result": "curl_cffi missing"}
    try:
        r = cffi.get(url, impersonate="chrome", timeout=15)
        return {"result": "reached", "status": r.status_code}
    except Exception as e:
        return {"result": "blocked/error", "detail": f"{type(e).__name__}: {str(e)[:160]}"}


def _direct_connect(host: str, port: int = 443, family: int = socket.AF_INET) -> dict:
    """Attempt a direct TCP connection, bypassing the proxy entirely. Must fail."""
    try:
        infos = socket.getaddrinfo(host, port, family, socket.SOCK_STREAM)
        ip = infos[0][4][0]
    except Exception as e:
        return {"dns": f"failed ({type(e).__name__})", "connect": "n/a (no DNS)"}
    s = socket.socket(family, socket.SOCK_STREAM)
    s.settimeout(6)
    try:
        s.connect((ip, port))
        s.close()
        return {"dns": ip, "connect": "CONNECTED — LEAK!"}
    except Exception as e:
        return {"dns": ip, "connect": f"failed ({type(e).__name__})"}


def main() -> None:
    out = {
        "proxy": PROXY,
        "via_proxy_requests": {u: _req_via_proxy(u) for u in ALLOW_HOSTS + DENY_HOSTS},
        "via_proxy_curl_cffi": {u: _cffi_via_proxy(u) for u in [ALLOW_HOSTS[0], DENY_HOSTS[0]]},
        "direct_no_proxy": {
            "google_ipv4": _direct_connect("www.google.com"),
            "raw_ip_1.1.1.1": _direct_connect("1.1.1.1"),
            "google_ipv6": _direct_connect("www.google.com", family=socket.AF_INET6),
        },
    }
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
