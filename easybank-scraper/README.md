# easybank / Barclaycard DE scraper sidecar

A small, network-isolated FastAPI service that logs in to
`banking.easybank.de`, reads the account balance + recent transactions, and
returns them as normalized JSON. It is the easybank counterpart to the Trade
Republic sidecar in [`../scraper/`](../scraper/), and it **replaces the
standalone feasibility gate** in [`../gate/`](../gate/) — the live-validation
command below is now the way you test a real login.

## How it works

easybank runs JS **device fingerprinting** (`crashninja`) and gates logins on a
**trusted-device cookie**. A pure HTTP client looks like a brand-new device and
gets challenged with an mTAN on every attempt. So, unlike the TR sidecar (which
stubs out the browser and talks an API over a websocket), this one drives a
**real, stealth Chromium** via [CloakBrowser](https://pypi.org/project/cloakbrowser/):

1. It opens the bank's own Angular UI (`/Login`), fills the credentials, and
   submits — driving the **VeriChannel** flow the way a human would.
2. It **captures the JSON** the app fetches in the background — `RetailLanding`
   (balance, IBAN, credit limits) and `AccountTransactionHistory`
   (transactions) — via `page.on('response')`. We never replay raw POSTs; the
   fingerprint + cookie only exist inside a genuine browser session.
3. A **persistent profile** (`/profile`, a durable volume) makes the container a
   *returning trusted device*, so subsequent logins are password-only. Lose that
   volume and the next login faces a one-time mTAN again.

The mapping from the captured JSON to the response contract lives in
[`app/normalize.py`](app/normalize.py) — pure, browser-free, and unit-tested.

### Architecture / egress isolation

```
kontor (Rails) ──HTTP + X-Sidecar-Token──► easybank-scraper (CloakBrowser)
                                                 │  ebnet (internal) ONLY
                                                 │  no internet, no DNS resolver
                                                 ▼  HTTPS_PROXY = egress proxy
                                            easybank-egress-proxy (squid)
                                              ebnet + web; does the DNS;
                                              CONNECT:443 allowlist only:
                                              .easybank.de  .crashninja.net
```

The sidecar has **no route off the box except the squid allowlist** — see
[`../compose.easybank.yml`](../compose.easybank.yml) and
[`../egress-proxy/easybank-squid.conf`](../egress-proxy/easybank-squid.conf).
Because it stores bank credentials and drives a real browser, that egress lock
is the security boundary. (It is deliberately **not** `read_only`: Chromium must
write its profile, `/dev/shm`, and temp dirs — a divergence from the hardened TR
image, noted in the Dockerfile.)

## HTTP API

All routes except `GET /health` require the `X-Sidecar-Token` header.

| Method & path | Body | Success | Notes |
|---|---|---|---|
| `GET /health` | — | `{status:"ok"}` | liveness for the compose healthcheck |
| `POST /login` | `{username, password}` | `200` sync result | may return `409 mtan_required` |
| `POST /mtan`  | `{pairing_id, code}` | `200` sync result | resumes a paused login |
| `POST /sync`  | `{username, password, backfill_days?=30}` | `200` sync result | `backfill_days:360` triggers an mTAN |

**Status taxonomy** (matches the Phase-2 Rails `EasyBank::ScraperClient`, which
mirrors `TradeRepublic::ScraperClient`):

- `200` — ok
- `409` — `mtan_required` (login needs an mTAN; body carries `pairing_id`,
  `masked_phone`, `reference`, `expires_in`) **or** `session_expired` (a paused
  mTAN context is gone — restart the login)
- `422` — `mtan_failed` (wrong/expired code) **or** `login_failed` (bad creds)
- `503` — `transient` (timeout / browser / network — retry)

The **success body** (`/login`, `/mtan`, `/sync`) is:

```jsonc
{
  "status": "ok",
  "balance":   { "value": "-123.45", "currency": "EUR" },
  "available": { "value": "1876.55", "currency": "EUR" },  // AvailableCreditLimit (card) / AvailableBalanceInLocalCurrency (giro)
  "account":   { "iban": "...", "number": "...", "name": "...", "type": "...",
                 "credit_limit": {...}, "available_credit": {...} },
  "transactions": [
    {
      "id": "900002", "booking_date": "2026-05-28", "value_date": "2026-05-29",
      "amount": "-49.55", "currency": "EUR",            // EUR SETTLED value (LocalCurrencyAmount)
      "original_amount": "-54.32", "original_currency": "USD",  // ORIGINAL/foreign value (Amount)
      "exchange_rate": 0.9123, "description": "AMZN Mktp US",
      "merchant": "Amazon US", "mcc": "5942",
      "is_pending": false, "type": "Purchase"
    }
  ],
  "otp_required": false
}
```

**Amount sign:** the bank returns transaction magnitudes **unsigned**; the
direction is in `TransactionNature` (`Debit`/`Credit`), confirmed by the sign in
`FormattedLocalAmount`. The sidecar signs **debits negative**, credits positive.
`amount` is the EUR figure actually booked to the account; `original_amount` is
the transaction's original-currency value (equal to `amount` for domestic
purchases). **Dates:** `BookingDate` is the .NET min-date until a row is booked,
so the sidecar falls back to the posting/value date and emits a plain `YYYY-MM-DD`.
**Pending** comes from `TransactionType == "Pending"` (the `IsPending` field is
unreliable — always false on this card).

## Running it

### Tests (pure, no browser)

```sh
uv run --with pytest python -m pytest easybank-scraper/tests -q
```

### Locally with Docker

```sh
# from the repo root
EASYBANK_SIDECAR_TOKEN=$(openssl rand -hex 32) \
  docker compose -f compose.easybank.yml up --build easybank-egress-proxy easybank-scraper
```

First launch downloads CloakBrowser's patched Chromium (~200 MB); give the
healthcheck its `start_period`.

### Locally without Docker (uv)

```sh
SIDECAR_TOKEN=dev PROFILE_DIR=./tmp/easybank-profile HEADLESS=false \
  uv run --with cloakbrowser --with playwright --with 'fastapi>=0.115' --with 'uvicorn[standard]>=0.32' \
  python -m uvicorn app.main:app --app-dir easybank-scraper --port 8000
```

(`HEADLESS=false` opens a visible window so you can watch / complete the login by
hand; drop `PROXY_URL` so it goes direct from your own machine — same IP as your
normal logins, which is the least bot-like option.)

## LIVE login validation (MANUAL — needs YOUR real credentials)

> This is a **manual user step**. It contacts the **real bank** with your **real
> account**, so it cannot be automated or run in CI. It replaces
> `gate/easybank_cloak.py`.

1. Start the sidecar locally (uv recipe above, `HEADLESS=false` recommended for
   the first run so you can complete any one-time mTAN in the browser window).
2. In another terminal, log in (this also returns balance + 30-day
   transactions). Put your credentials in env vars so they never hit your shell
   history:

   ```sh
   export EASYBANK_USER='your-username'
   export EASYBANK_PW='your-password'   # read, never logged or echoed by the sidecar

   curl -s -X POST http://localhost:8000/login \
     -H 'X-Sidecar-Token: dev' -H 'Content-Type: application/json' \
     -d "{\"username\":\"$EASYBANK_USER\",\"password\":\"$EASYBANK_PW\"}" | jq .
   ```

   - **`200`** with `balance` + `transactions` → password-only login worked
     (trusted device). Done.
   - **`409 mtan_required`** → note the `pairing_id`, read the SMS code, and
     submit it (within `expires_in` seconds):

     ```sh
     curl -s -X POST http://localhost:8000/mtan \
       -H 'X-Sidecar-Token: dev' -H 'Content-Type: application/json' \
       -d '{"pairing_id":"<from the 409 body>","code":"<sms code>"}' | jq .
     ```

     The profile volume now remembers the device, so the next `/login` should be
     password-only.

3. To validate the longer backfill (expect a fresh mTAN, since the bank gates
   far-back history behind a second factor):

   ```sh
   curl -s -X POST http://localhost:8000/sync \
     -H 'X-Sidecar-Token: dev' -H 'Content-Type: application/json' \
     -d "{\"username\":\"$EASYBANK_USER\",\"password\":\"$EASYBANK_PW\",\"backfill_days\":360}" | jq .
   ```

**Validate against your statement:** confirm the **sign** of a known debit and
credit, and that a **foreign-currency** transaction shows the EUR value in
`amount` and the original currency in `original_amount`. If the sign is ever
inverted, flip it in the single documented spot in `app/normalize.py` (`_amounts`).
