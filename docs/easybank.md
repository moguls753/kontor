# easybank / Barclaycard DE balance + transactions (egress-locked scraper)

The German **easybank Kreditkarte** (Barclaycard-operated) exposes **no
open-banking (XS2A) interface** and is reachable by no free aggregator
(confirmed against GoCardless and Enable Banking). Its online banking is a
**VeriChannel Angular single-page app** at `banking.easybank.de` that talks to a
private JSON API. The only way to read the card automatically is to drive that
app. Kontor does this with a small Python sidecar that runs a **real, stealth
headless Chromium** ([CloakBrowser](https://pypi.org/project/cloakbrowser/)),
logs in the way a human would, and captures the JSON the page fetches in the
background — the balance, credit limits, and transactions.

Storing your easybank credentials is only acceptable because the sidecar is
**network-isolated**: it can reach nothing but easybank and the device-
fingerprinting host its login page loads. That guarantee is proven, not
asserted — see *Verifying the lockdown*.

> **Unofficial & best-effort.** This drives a private banking UI, against
> easybank's terms. It can break whenever they change their app, and the
> trusted-device pairing (one-time SMS mTAN) has to be redone if the device
> profile is lost. The captured-JSON normalization is pinned and unit-tested for
> reproducibility.

## Why a browser (and not a bare HTTP client)

easybank runs JS **device fingerprinting** (the `crashninja` SDK its page loads)
and gates logins on a **trusted-device cookie**. A pure HTTP client looks like a
brand-new device and is challenged with an SMS mTAN on *every* attempt. A
genuine browser session with a **persistent profile** reproduces the
fingerprint and remembers the device, so day-to-day logins are password-only.

This is the deliberate divergence from the Trade Republic sidecar
([`docs/trade-republic.md`](trade-republic.md)): that one **stubs out the
browser** and solves an AWS WAF challenge in pure Python over a websocket; this
one **needs the real Chromium**. They are separate stacks and never share a
network.

## Architecture

```
┌──────────── docker compose (TrueNAS "Custom App") ─────────────────┐
│  kontor (Rails)  ──HTTP + X-Sidecar-Token──►  easybank-scraper      │
│   • direct to the internet for EB/GC/LLM       (Python / CloakBrowser)│
│                                                • ebnet ONLY          │
│                                                • no internet         │
│                                                • no DNS resolver     │
│                                                     │ HTTPS_PROXY    │
│                                                     ▼                │
│                                              easybank-egress-proxy   │
│                                               (squid)                │
│                                               • ebnet + web           │
│                                               • does the DNS          │
│                                               • CONNECT :443 allow:   │
│                                                 .easybank.de          │
│                                                 .crashninja.net       │
└─────────────────────────────────────────────────────────────────────┘
```

- **`easybank-scraper`** (`easybank-scraper/`) — FastAPI + CloakBrowser. Three
  jobs: log in (password-only on a trusted device, else pause for an mTAN),
  submit the SMS mTAN to finish device pairing, and read the balance +
  transactions from the already-paired profile. It is on the `ebnet` network
  **only** — no route off the box and no working DNS, so its sole path out is
  the proxy allowlist.
- **`easybank-egress-proxy`** (`egress-proxy/easybank-squid.conf`) — squid
  configured to allow **only** `CONNECT` to `:443` for `.easybank.de` and
  `.crashninja.net`; every other destination (and all plain HTTP) is denied.
  squid performs the DNS.
- **`kontor`** — the Rails app, reaching the sidecar over `ebnet` with a shared
  `X-Sidecar-Token`.

### Why two domains in the allowlist

The login page loads the **`crashninja.net`** device-fingerprint / fraud SDK.
Blocking it makes the session look bot-like and can force an mTAN on every
login, defeating the trusted-device profile. An `.easybank.de`-only allowlist
therefore isn't enough — `.crashninja.net` is required for the browser to look
like a returning, trusted device.

### Not as hardened as the TR sidecar — on purpose

Unlike `tr-scraper` (read-only rootfs, all capabilities dropped, session blobs
on tmpfs), this container is **not** `read_only` and is **not** cap-stripped to
the bone: a real Chromium must write its profile, `/dev/shm`, and temp dirs and
needs the syscalls to spawn renderer processes. The egress lock-down (internal
network + allowlist proxy) is the security boundary here, not a read-only
filesystem. The one cheap hardening that doesn't break Chromium —
`no-new-privileges:true` — is kept.

## Data quirks (what `normalize.py` encodes)

The VeriChannel JSON nests the useful data deep and inconsistently (domestic vs.
foreign cards differ), so the sidecar searches by key rather than assuming a
fixed path. Several fields are actively misleading and are normalized in
[`easybank-scraper/app/normalize.py`](../easybank-scraper/app/normalize.py):

- **Amounts arrive UNSIGNED.** A debit's magnitude is `+26.80`, not `-26.80`.
  The direction lives in **`TransactionNature`** (`Debit`/`Credit`), which the
  sidecar applies — debits negative, credits positive. If that field is ever
  missing it falls back to the sign printed in the bank's own formatted string
  (`FormattedLocalAmount`, e.g. `"-26,80 €"`).
- **EUR settled vs. original/foreign.** `LocalCurrencyAmount` is the amount
  settled to the account, in EUR — **this** is what Kontor books as `amount`.
  `Amount` is the **original** amount in its own currency (equal to the EUR
  figure for a domestic purchase, the foreign value for a foreign one) and
  becomes `original_amount` + `original_currency`, paired with `ExchangeRate`.
  The bank sends `ExchangeRate: 0.0` on domestic rows, which is dropped.
- **`BookingDate` is the .NET min-date (`0001-01-01`) until a row is booked.**
  The sidecar treats that sentinel as null and falls back across
  `PostingDate` / `ValueDate` / `TransactionDate` / `EffectiveDate`, always
  emitting a plain `YYYY-MM-DD`.
- **Pending is NOT `IsPending`.** That field is unreliable on this card (always
  false). The real signal is the booking status in **`TransactionType`**
  (`"Pending"` / `vorgemerkt` ⇒ pending, vs. `Unbilled`/`Billed` ⇒ booked).
- **Money is quantized via `Decimal`.** JSON parsing turns the bank's literals
  into floats (`"26.80"` → `26.8`, with possible binary noise), so every money
  value is re-quantized to a stable 2-dp string.

These rules are pure and **unit-tested without a browser**
(`easybank-scraper/tests/test_normalize.py`); the browser code hands the raw
captured dicts to `normalize()`.

## Login, mTAN, and the backfill window

- **Connect and daily sync both fetch the last ~30 days, password-only.** On a
  trusted-device profile the login goes straight through and the sidecar returns
  the full sync payload; both the connect flow and the background job use the
  sidecar's default **30-day** window.
- **A fresh/untrusted device is challenged with a one-time SMS mTAN at connect.**
  The first login from a profile the bank doesn't recognise returns
  `mtan_required` (a `pairing_id` + masked phone); the UI shows the code modal,
  and submitting it pairs the device so later logins are password-only.
- **Deep-history (360-day) backfill is a sidecar capability, not yet wired.** The
  sidecar supports a long backfill (`backfill_days ≥ 360`, which easybank gates
  behind a second factor, `OTPRequired`), but **no Rails caller requests it
  today** — connect and the background job both use 30 days, so there is
  currently no automatic one-time deep backfill. See *Future work*.
- **Background syncs never submit an mTAN.** If one ever returns
  `otp_required: true`, Kontor treats it like an expired session: the connection
  is marked **Expired** and you reconnect (where the interactive mTAN flow lives).

The sidecar's HTTP taxonomy (matched by `EasyBank::ScraperClient`): `200` ok;
`409` is overloaded — `mtan_required` (continue the flow; body carries
`pairing_id`, `masked_phone`, `reference`, `expires_in`) **or** `session_expired`
(re-pair) — told apart by the body's `error` field, not the status; `422` is
`mtan_failed` (wrong/expired code) or `login_failed` (bad credentials); `503` is
transient (timeout / browser / network — retried, never expires the connection).

## Deploying on TrueNAS

The full production stack is the merged **[`compose.yml`](../compose.yml)** — one
TrueNAS **Custom App** with five services: `kontor` (Rails) + the Trade Republic
sidecar (`tr-scraper` + `tr-egress-proxy`) + the easybank sidecar
(`easybank-scraper` + `easybank-egress-proxy`), each scraper egress-locked to its
own bank via its own squid allowlist on its own internal network. (The per-sidecar
files [`compose.easybank.yml`](../compose.easybank.yml) and `compose.scraper.yml`
remain for running or egress-gating a single sidecar standalone.)

1. Copy `.env.example` to `.env` and fill in:
   - `RAILS_MASTER_KEY` — your `config/master.key`.
   - `EASYBANK_SIDECAR_TOKEN` and `SCRAPER_SIDECAR_TOKEN` — shared secrets
     (`openssl rand -hex 32` each).
2. Create a TrueNAS **Custom App** from `compose.yml` (or run
   `docker compose -f compose.yml up -d --build`). The first build downloads
   CloakBrowser's patched Chromium (~200 MB) and bakes it into the easybank
   image; give the healthchecks their `start_period`.

> **Critical:** the `kontor` service **must** run with `RAILS_ENV=production` and
> `SOLID_QUEUE_IN_PUMA=true`. Solid Queue's recurring scheduler only runs inside
> Puma under these settings (`config/puma.rb`; `config/recurring.yml` is
> `production:`-keyed). Without them **no** recurring jobs fire — neither the
> daily scraped-balance sync nor the existing open-banking sync.

Relevant Rails env (wired in compose):

| Variable | Purpose |
|---|---|
| `EASYBANK_SIDECAR_URL` | `http://easybank-scraper:8000` |
| `EASYBANK_SIDECAR_TOKEN` | shared secret sent as `X-Sidecar-Token` |

### Docker / egress deploy gotchas (already fixed)

Five non-obvious failures were hit and fixed while making the egress-locked,
real-browser sidecar run unattended on TrueNAS:

1. **Bake Chromium at build time.** CloakBrowser ships its own patched Chromium
   (~200 MB) and would normally fetch it on first launch — but the runtime is
   egress-locked to the bank's hosts only, so the download host isn't reachable.
   The Dockerfile runs `cloakbrowser.ensure_binary()` at build (open internet),
   making the runtime image self-contained. A failed fetch fails the build
   loudly — no `|| true`.
2. **`CLOAKBROWSER_AUTO_UPDATE=false`.** Its background auto-update fires daemon
   threads that hit PyPI/GitHub — useless on an egress-locked runtime, and at
   build time a daemon thread mid-request segfaults the interpreter on exit.
   Off ⇒ no threads, clean build, no runtime phone-home.
3. **No `xvfb-run` wrapper.** CloakBrowser's stealth Chromium needs no display in
   headless mode (validated live). An earlier `xvfb-run` PID-1 wrapper started
   Xvfb but never brought uvicorn up and swallowed its stdout (empty logs).
   uvicorn now runs directly as the entrypoint.
4. **`chown /profile` in the image.** Docker copies the image dir's owner into a
   fresh empty named volume. Without pre-creating and `chown`-ing `/profile` to
   the non-root `scraper` user, Chromium can't write its `SingletonLock` there
   and the launch aborts (**exit 21**).
5. **`_launch()` lives inside the request `try`.** The Chromium spawn is inside
   the `login`/`sync` try-block so a launch failure surfaces as a clean
   transient `503` (retried) rather than crashing the worker.

The persistent **`easybank-profile`** volume is the trusted-device store and
**must be durable** (a real rw volume, not tmpfs): lose it and the next login
faces a fresh-device mTAN again.

## Verifying the lockdown

The egress guarantee is the whole justification for storing credentials, so
prove it. The squid access log is the authoritative artifact — every `CONNECT`
host must be inside the allowlist:

```bash
docker compose -f compose.yml exec easybank-egress-proxy \
  cat /var/log/squid/access.log
# every line → a host under .easybank.de or .crashninja.net, nothing else
```

`easybank-scraper/README.md` documents the manual, real-credentials live login
validation (it contacts the real bank, so it can't be automated or run in CI),
and the pure normalization unit tests:

```bash
uv run --with pytest python -m pytest easybank-scraper/tests -q
```

## Using it

1. **Settings → easybank → Configure.** Enter your easybank online-banking
   username and password. These are encrypted at rest (ActiveRecord encryption);
   the password is never returned by the API and the username is shown masked.
2. **Connect a Bank → easybank** (or it's auto-selected if it's your only
   provider). On a trusted-device profile the login is password-only and a
   single "easybank Kreditkarte" account appears immediately, with its balance,
   credit limit, and the **last ~30 days** of transactions. (A one-time
   deep-history backfill isn't wired yet — see *Future work*.)
   - If the device isn't trusted yet, an **SMS mTAN** is sent: the modal shows a
     masked phone number; enter the code (within its validity window) and the
     profile then remembers the device.
3. The balance + recent transactions refresh **daily at 04:00 Europe/Berlin**
   (`SyncScrapedBalancesJob`, with per-connection jitter, capped to a 30-day
   backfill), and on demand via the **Sync** button.

### Re-pairing

If the saved session lapses, or the trusted-device profile is lost (e.g. the
`easybank-profile` volume was recreated), the daily sync marks the connection
**Expired** and the Accounts page shows a **Reconnect** button — which re-runs
the login, prompting for a fresh SMS mTAN if needed. Transient failures (sidecar
down, browser/network hiccup, upstream 5xx) are retried and never expire the
connection.

## Operational notes & threat model

- **Secrets:** the username + password are replayed to the sidecar on every
  sync (a browser login, unlike Trade Republic's cookie-only daily fetch). The
  sidecar never logs credentials, the mTAN code, tokens, card numbers, or
  balances; request bodies are never logged, and `cloakbrowser`/`playwright`
  loggers are pinned to `WARNING`.
- **Shared-secret model:** any container on `ebnet` holding the token can drive
  the sidecar. Acceptable for a single-user home server; the egress allowlist
  means even a compromised token can exfiltrate nothing beyond easybank and the
  fingerprint host.
- **mTAN context lifetime:** a paused, mTAN-pending browser context is held in
  memory only for the bank's code-validity window (`MTAN_TTL_S`, default 300 s);
  a sweeper closes any that outlive it so neither Chromium processes nor the
  in-memory registry leak.
- **Validate against your statement** after the first connect: confirm the
  **sign** of a known debit and credit, and that a **foreign-currency**
  transaction shows the EUR value in `amount` and the original currency in
  `original_amount`. If the sign is ever inverted, it's flipped in one
  documented spot (`_amounts` in `normalize.py`).

## Future work

- **Wire the one-time 360-day backfill.** The sidecar already supports
  `backfill_days ≥ 360`; the connect flow could request it on first pair (routing
  the resulting `OTPRequired` through the existing mTAN modal) so a new connection
  starts with deep history instead of only the last 30 days.
- **Scalable Capital** has the same "no aggregator" problem and can reuse this
  CloakBrowser + allowlist framework (out of scope here).
