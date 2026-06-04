# Trade Republic balance (egress-locked scraper)

Trade Republic exposes **no open-banking (XS2A) interface** and is reachable by
no free aggregator (confirmed against GoCardless and Enable Banking). The only
way to read your balance automatically is to drive their private app API. Kontor
does this with a small Python sidecar wrapping [`pytr`](https://github.com/pytr-org/pytr),
fetching **only the account's total balance, once a day** (no transactions).

Storing your Trade Republic credentials is only acceptable because the sidecar
is **network-isolated**: it can reach nothing but Trade Republic and the AWS WAF
token host. That guarantee is proven, not asserted — see *Verifying the lockdown*.

> **Unofficial & best-effort.** This uses a private API, against Trade Republic's
> terms. It can break whenever they change their app, and periodic re-pairing
> (2FA) is unavoidable. `pytr` is pinned to an exact version for reproducibility.

## Architecture

```
┌──────────── docker compose (TrueNAS "Custom App") ─────────────┐
│  kontor (Rails)  ──HTTP + X-Sidecar-Token──►  tr-scraper        │
│   • appnet + web (internet)                    (Python / pytr)  │
│   • EB / GC / LLM go direct to the internet    • appnet ONLY    │
│                                                • no internet     │
│                                                • no DNS resolver │
│                                                     │ HTTPS_PROXY│
│                                                     ▼            │
│                                              egress-proxy (squid)│
│                                               • appnet + web      │
│                                               • does the DNS      │
│                                               • CONNECT :443 allow│
│                                                 .traderepublic.com│
│                                                 .awswaf.com       │
└─────────────────────────────────────────────────────────────────┘
```

- **`tr-scraper`** (`scraper/`) — FastAPI + `pytr`. Two jobs: pair a web session
  (2-step weblogin) and read the total balance from a saved cookie session. It is
  on the `appnet` network **only** — it has no route off the box and no working
  DNS, so its sole path out is the proxy allowlist. Runs non-root, read-only root
  filesystem, all capabilities dropped, session blobs only ever touch a tmpfs.
- **`egress-proxy`** (`egress-proxy/squid.conf`) — squid configured to allow
  **only** `CONNECT` to `:443` for `.traderepublic.com` and `.awswaf.com`; every
  other destination (and all plain HTTP) is denied. squid performs the DNS.
- **`kontor`** — the Rails app, reaching the sidecar over `appnet` with a shared
  `X-Sidecar-Token`.

### Why two domains in the allowlist

Trade Republic's login is protected by an **AWS WAF challenge**. `pytr`'s
pure-Python solver fetches `challenge.js` and mints an `aws-waf-token` from a
host under **`*.awswaf.com`** (e.g. `…eu-central-1.token.awswaf.com`) before the
login POST to `api.traderepublic.com` is accepted. A Trade-Republic-only
allowlist therefore **cannot complete login** — `.awswaf.com` is required.

No headless browser is used: `playwright` is intentionally absent from the image
(the pure-Python `awswaf` solver does the work; a tiny stub satisfies `pytr`'s
module-level import).

## Deploying on TrueNAS

The scraper stack is fully opt-in: if you don't start these services, today's
single-container Kontor is unchanged, and the Kamal config is untouched.

1. Copy `.env.example` to `.env` and fill in:
   - `SCRAPER_SIDECAR_TOKEN` — a shared secret (`openssl rand -hex 32`).
   - `RAILS_MASTER_KEY` — your `config/master.key`.
2. Create a TrueNAS **Custom App** from `compose.scraper.yml` (or run it with
   `docker compose -f compose.scraper.yml up -d --build`).

> **Critical:** the `kontor` service **must** run with `RAILS_ENV=production` and
> `SOLID_QUEUE_IN_PUMA=true` (both set in `compose.scraper.yml`). Solid Queue's
> recurring scheduler only runs inside Puma under these settings
> (`config/puma.rb`, `config/recurring.yml` is `production:`-keyed). Without them
> **no** recurring jobs fire — neither the daily Trade Republic balance nor the
> existing 6-hour open-banking sync.

Relevant Rails env (already wired in compose):

| Variable | Purpose |
|---|---|
| `SCRAPER_SIDECAR_URL` | `http://tr-scraper:8000` |
| `SCRAPER_SIDECAR_TOKEN` | shared secret sent as `X-Sidecar-Token` |

## Verifying the lockdown

The egress guarantee is the whole justification for storing credentials, so
prove it before trusting it. With the stack up:

```bash
# Adversarial isolation audit — runs inside the sidecar, exercises both HTTP
# stacks pytr uses (requests + curl_cffi):
docker compose -f compose.scraper.yml exec -T tr-scraper python - < gate/egress_audit.py
```

Expected: Trade Republic and `*.awswaf.com` are reachable **through** the proxy;
`google.com`/`example.com` are denied (`403`); and **around** the proxy there is
no DNS and no route (IPv4, IPv6, raw IP all fail).

During a real pairing, the squid access log is the authoritative artifact — every
`CONNECT` host must be inside the allowlist:

```bash
docker compose -f compose.scraper.yml exec egress-proxy \
  grep CONNECT /var/log/squid/access.log
# every line → app/api.traderepublic.com or *.token.awswaf.com, nothing else
```

`gate/live_balance.py` drives a full real pair + balance through the sidecar for
end-to-end verification.

## Using it

1. **Settings → Trade Republic → Configure.** Enter your phone number
   (international format, `+49…`) and PIN. These are encrypted at rest
   (ActiveRecord encryption); the PIN is never returned by the API and the phone
   is shown masked.
2. **Connect a Bank → Trade Republic** (or it's auto-selected if it's your only
   provider). A login notification is pushed to your phone; enter the code in the
   modal. On success a single "Trade Republic" account appears and its balance is
   fetched immediately.
3. The balance refreshes **daily at 04:00 Europe/Berlin** (`SyncScrapedBalancesJob`,
   with per-connection jitter), and on demand via the **Sync** button.

### Re-pairing

Trade Republic periodically requires fresh strong authentication (SCA), and the
cookie session can lapse. When it does, the daily sync marks the connection
**Expired** and the Accounts page shows a **Reconnect** button — which opens the
same 2FA modal to re-pair. (Transient failures — sidecar down, upstream 5xx — are
retried and never expire the connection.)

## Operational notes & threat model

- **Balance** = `cash(EUR) + Σ(price × netSize)` over portfolio positions, using
  `pytr`'s proven `compactPortfolio` + per-instrument details + `ticker` path
  (with bond price ÷ 100 handling). Validate against the figure in the TR app.
- **Secrets:** the PIN is only used during pairing; the daily balance fetch is
  cookie-only (no PIN). Session blobs live on a tmpfs, `chmod 600`, deleted after
  each request; `pytr`'s logger is pinned to `WARNING` so it never logs the WAF
  token, login JSON, or websocket traffic.
- **Shared-secret model:** any container on `appnet` holding the token can drive
  the sidecar. Acceptable for a single-user home server; the egress allowlist
  means even a compromised token can exfiltrate nothing beyond Trade Republic.
- **`websockets` is pinned `>=16`** deliberately: squid answers the proxy
  `CONNECT` with HTTP/1.0, which `websockets` < 16 rejects — that would silently
  break the `wss://api.traderepublic.com` balance path.

## Future work

Scalable Capital and the German easybank/Barclaycard card have the same "no
aggregator" problem and can reuse this sidecar + allowlist framework (out of
scope here).
