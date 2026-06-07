# PayPal personal-account scraper sidecar

A small, network-isolated FastAPI service that logs in to `www.paypal.com`,
DOM-scrapes the recent activity list, and returns it as normalized JSON. It is
the PayPal counterpart to the [`../easybank-scraper/`](../easybank-scraper/) and
[`../scraper/`](../scraper/) sidecars, and it productionizes the feasibility spike
in [`../gate/`](../gate/).

**Manual sync only.** A normal login surfaces PayPal's **device step-up** (a
PayPal-app push approved out-of-band on the user's phone), and the session does
NOT persist across launches, so there is no background/scheduled sync — only a
single blocking `/sync` request while the user is present to approve.

## How it works

Personal PayPal accounts cannot get live REST API credentials, so — like
easybank — this drives PayPal's own web UI as the user via a **real, stealth
Chromium** ([CloakBrowser](https://pypi.org/project/cloakbrowser/)):

1. It opens `/signin`, fills the credentials (2-step `#email` → `#btnNext` →
   `#password` → `#btnLogin`, or single form), with **humanized** mouse + typing.
2. On the **device step-up** (`/authflow`) it picks the PayPal-app option, fires
   the push, and **blocks inside the one request** polling `page.url` for
   `/myaccount` until the user approves on their phone (bounded by
   `PUSH_DEADLINE_S`). There is nothing to type — so, unlike the easybank mTAN,
   there is no `/login` + `/mtan` split and no paused-context registry.
3. It navigates to `/myaccount/activities?start_date=…&end_date=…` and
   **DOM-scrapes each row ONCE — no expand, no XHR.** The stable 17-char
   Transaktionscode is read off the row's `js_transactionItem-<txid>` class
   (fallback `aria-controls="transactionDetails-<txid>"`).
4. A **persistent profile** (`/profile`, a durable volume) is the warmed device.
   A **pinned `--fingerprint`** (`PP_FINGERPRINT`, required) keeps PayPal seeing
   one stable device across syncs; `humanize=True` + Rails-side ~1/day
   rate-limiting are the captcha-avoidance levers (we never solve captchas — a
   security check returns a non-retryable `captcha_blocked`).

The mapping from scraped rows to the response contract lives in
[`app/normalize.py`](app/normalize.py) — pure, browser-free, and unit-tested.

### Architecture / egress isolation

```
kontor (Rails) ──HTTP + X-Sidecar-Token──► paypal-scraper (CloakBrowser)
                                                 │  pp-net (internal) ONLY
                                                 │  no internet, no DNS resolver
                                                 ▼  HTTPS_PROXY = egress proxy
                                            paypal-egress-proxy (squid)
                                              pp-net + web; does the DNS;
                                              CONNECT:443 allowlist only:
                                              .paypal.com + reCAPTCHA hosts
                                              (+ a TODO device-SDK host)
```

The sidecar has **no route off the box except the squid allowlist** — see
[`../egress-proxy/paypal-squid.conf`](../egress-proxy/paypal-squid.conf). The
exact device-fingerprint/fraud SDK host is **confirmed at deploy** by running one
login through the squid with deny-all logging and reading the denied CONNECT host.

## HTTP API

All routes except `GET /health` require the `X-Sidecar-Token` header.

| Method & path | Body | Success | Notes |
|---|---|---|---|
| `GET /health` | — | `{status:"ok"}` | liveness for the compose healthcheck |
| `POST /sync`  | `{username, password, date_from?, date_to?}` | `200` sync result | one blocking call (login + push + scrape); defaults to the last 30 days |

**Status taxonomy** (the Rails `Paypal::ScraperClient` depends on these):

- `200` — ok
- `409` — `push_timeout` (device push not approved within `PUSH_DEADLINE_S`)
- `422` — `login_failed` (bad creds) **or** `captcha_blocked` (security check;
  non-retryable)
- `503` — `transient` (timeout / browser / network — retry)

The **success body** is:

```jsonc
{
  "status": "ok",
  "date_from": "2026-05-07",
  "date_to": "2026-06-06",
  "transactions": [
    {
      "id": "55X63072JY995300U",       // Transaktionscode (row class) else "pp-syn-…"
      "merchant": "eBay S.a.r.l.",
      "description": "Zahlung",          // the transaction TYPE (date is stripped)
      "amount": "-8.15",                 // signed 2dp Decimal string, NOT NULL
      "currency": "EUR",                 // ISO-4217; trailing token preferred, else symbol
      "booking_date": "2026-06-06",      // YYYY-MM-DD, within [date_from, date_to]
      "is_pending": false                // booked-only (PayPal lists only completed)
    }
  ]
}
```

**Amount sign** is taken straight from PayPal's signed text (`−8,15 €` →
`-8.15`); the U+2212 minus and U+00A0 nbsp are normalized and the German locale
de-localized. **Currency** prefers a trailing ISO token (`−10,60 $ USD` → `USD`)
over the symbol; an FX row books the **foreign** amount + ISO (there is no EUR
figure in the list without the forbidden inline XHR). **Dates** are fused with the
type in `transaction_description` (`"6. Juni . Zahlung"`, split on `" . "`); the
year is carried from `Monat JJJJ` headers in a single document-order walk, else
derived from today (a future date steps back a year), and **fail-loud**
sanity-bounded to the queried window. **Pending** is always `false` (PayPal's list
shows only completed activity).

## Running it

### Tests (pure, no browser)

```sh
uv run --with pytest python -m pytest paypal-scraper/tests -q
```

### Locally without Docker (uv)

```sh
SIDECAR_TOKEN=dev PP_FINGERPRINT=61803 PROFILE_DIR=./tmp/paypal-profile HEADLESS=false \
  uv run --with cloakbrowser --with playwright --with 'fastapi>=0.115' --with 'uvicorn[standard]>=0.32' \
  python -m uvicorn app.main:app --app-dir paypal-scraper --port 8000
```

(`HEADLESS=false` opens a visible window for the first run; drop `PROXY_URL` so it
goes direct from your own machine — same IP as your normal logins, least bot-like.)

## LIVE login validation (MANUAL — needs YOUR real credentials)

> This is a **manual user step**: it contacts the **real PayPal** with your
> **real account**, so it cannot be automated or run in CI.

1. Start the sidecar locally (`HEADLESS=false` recommended for the first run so
   you can watch the device-push approval).
2. In another terminal:

   ```sh
   export PAYPAL_USER='your-email'
   export PAYPAL_PW='your-password'   # read, never logged or echoed by the sidecar

   curl -s -X POST http://localhost:8000/sync \
     -H 'X-Sidecar-Token: dev' -H 'Content-Type: application/json' \
     -d "{\"username\":\"$PAYPAL_USER\",\"password\":\"$PAYPAL_PW\"}" | jq .
   ```

   Approve the PayPal-app notification on your phone when prompted. A `200` with
   `transactions` means it worked; `409 push_timeout` means the push wasn't
   approved in time; `422 captcha_blocked` means a security check appeared
   (try again later).

**Pre-flight to confirm during the build** (see `../PAYPAL_SCRAPER_PLAN.md` §10):
that the same transaction keeps the **same** `js_transactionItem-<txid>` across
two logins (the dedup key), that humanized-headless logs in **captcha-free**, and
the squid's real CONNECT host set (incl. the device-SDK host).
