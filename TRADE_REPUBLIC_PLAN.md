# Plan: Trade Republic balance via an egress-locked scraper sidecar

## Context

Trade Republic (and later Scalable Capital, the German easybank/Barclaycard card) cannot be reached by any free open-banking aggregator — confirmed against GoCardless (live) and Enable Banking (its public ASPSP list). They expose no XS2A interface. The only automation path is scraping their private app API.

User requirements: **Trade Republic first**; import **only the current total balance, once a day** (no transactions); run on a **TrueNAS home server, local access only** → docker-compose (TrueNAS "Custom App"), not Kamal. The user accepts storing credentials **only because the scraper is network-isolated so it can reach nothing but Trade Republic** — the egress guarantee is the entire justification, so it must be *proven*, not asserted.

We wrap `pytr` in a small Python sidecar, lock its network egress through an allowlisting proxy, and integrate it as a new `trade_republic` provider — reusing Kontor's provider-agnostic `Account`/`BankConnection`/sync machinery and the `expired`→Reconnect UX built earlier this session.

> This plan has been through two adversarial reviews (incl. a max-effort pass). Blocking fixes are folded in and tagged **[R]**.

### Validated facts (pytr 0.4.10 source + library/docs verification)
- Web-login/cookie-only; 2FA = app push (SMS via resend). Reusable session = **the `cookies.txt` jar only**. `resume_websession()` (`api.py:262-289`) uses cookies only → **no PIN needed to refresh balance**, only to (re)pair. `account.login()` is interactive (`input()`/`getpass()`); call `initiate_weblogin()`/`complete_weblogin(code)` on `TradeRepublicApi` directly.
- **[R] Balance = pytr's proven path: `compactPortfolio` + per-instrument `ticker` + `cash`** → `total = cash + Σ(price×netSize)` (`portfolio.py:86-292`). `compactPortfolio` alone has **no market value** — tickers are required. `portfolioAggregateHistory` is a time-series and risks double-counting cash; only use it if Phase 1 proves `latest(history)+cash == app total`. `cash()` returns a **list of currency buckets** — define handling (use EUR bucket; reject/flag non-EUR). Cash-only accounts: `compact_portfolio` raises `ValueError` if no `_sec_acc_no` (`api.py:447`) → catch → securities=0.
- **[R] Egress: pin `websockets>=16,<17`.** Squid answers `CONNECT` with **HTTP/1.0**; websockets **15.x rejects HTTP/1.0 proxy replies** (raises at connect) — HTTP/1.0-proxy support landed in **16.0**. 15.x would silently break the `wss://api.traderepublic.com` path (`api.py:324`). Confirm pytr's `additional_headers=` kwarg still exists on 16.x (it does).
- Login mints an AWS WAF token from **`*.awswaf.com`** (host derived from `challenge.js`, `api.py:115,120`; calls `/inputs|verify|mp_verify`, `aws.py:133,220,229`) → allowlist = **`.traderepublic.com` + `.awswaf.com`**. All HTTPS → CONNECT-tunneled. Use `waf_token="awswaf"` (pure-Python solver); **drop `playwright`**. Solver uses **two HTTP stacks** — `curl_cffi` (`aws.py:109`) and stdlib `requests` for the `mp_verify` branch (`aws.py:219`); both honor `HTTPS_PROXY` **only if it's exported in the container env** — verify, both branches, live.

## Architecture

```
┌──────────── docker-compose (TrueNAS Custom App) ────────────┐
│  kontor (Rails)  ──HTTP + X-Sidecar-Token──►  tr-scraper     │
│   • appnet (internal) + web (internet)         (Python/pytr) │
│   • RAILS_ENV=production, SOLID_QUEUE_IN_PUMA=true [R]        │
│   • EB/GC/LLM go direct to internet            • appnet ONLY │
│                                                • NO internet  │
│                                                • NO local DNS │
│                                                     │ HTTPS_PROXY
│                                                     ▼         │
│                                              egress-proxy (squid)
│                                               • appnet + web   │
│                                               • does the DNS   │
│                                               • CONNECT:443 allow│
│                                                 .traderepublic.com
│                                                 .awswaf.com    │
└──────────────────────────────────────────────────────────────┘
```
- `tr-scraper` is on `internal: true` **only** → no internet, no working external DNS. It must NOT pre-resolve: HTTP clients send the hostname in the proxy `CONNECT`; **squid does all DNS** (it's on `web`).
- **[R] Jobs prerequisite:** the recurring scheduler runs only via Solid Queue, which here runs in Puma when `SOLID_QUEUE_IN_PUMA=true` and the env is `production` (`puma.rb:38`, `recurring.yml` is `production:`-keyed). The Kamal `deploy.yml` sets this; the **TrueNAS compose must also set `RAILS_ENV=production` + `SOLID_QUEUE_IN_PUMA=true`** (or run a `bin/jobs` supervisor) — otherwise the daily TR job *and the existing 6h sync* never fire.
- Fully opt-in: don't start these services → today's single-container setup unchanged. Kamal config untouched.

## Egress isolation — load-bearing; must be PROVEN (Phase-1 gate)

**Topology:** `appnet` (`internal: true`, `enable_ipv6: false`) = kontor + tr-scraper + egress-proxy; `web` (bridge) = kontor + egress-proxy (NOT tr-scraper). `tr-scraper`: no published ports, no persistent-secret volumes, no usable resolver, env `HTTPS_PROXY=http://egress-proxy:3128` **exported** (so all clients incl. stdlib `requests` inherit it), `NO_PROXY` minimal.

**squid.conf (complete — a 3-liner won't start):**
```
http_port 3128
acl SSL_ports port 443
acl CONNECT method CONNECT
acl allowed_domains dstdomain .traderepublic.com .awswaf.com
http_access deny CONNECT !SSL_ports
http_access allow CONNECT allowed_domains
http_access deny all
```

**Phase-1 adversarial gate — all must pass before ANY Rails work:**
1. Through proxy: `HTTPS_PROXY=… curl https://app.traderepublic.com` → allowed; an `*.awswaf.com` host → allowed; `https://www.google.com` → **403 denied by squid**.
2. Around proxy (no env): `curl https://www.google.com`, `curl -6 https://google.com`, raw-IP `curl https://1.1.1.1` → **all fail (no route)**.
3. Real pytr flow (pair + balance + `wss://`) **succeeds** through the proxy with `websockets>=16` — proving proxy-side DNS + CONNECT tunneling + both WAF-solver branches.
4. **[R] Artifact:** capture squid `access.log` during a live pairing and **assert every CONNECT host ∈ {*.traderepublic.com, *.awswaf.com}** (no cloudfront/other). 
5. **[R] Artifact:** confirm the balance number returned **equals the figure shown in the TR app** (the one number the feature exists to produce).

## Components

### 1. Python sidecar — `scraper/` (new dir, own image)
FastAPI + `pytr`. Stateless fetches (blob in→out); pairing state held in-process by `pairing_id` (5-min TTL, evicted on finish/error). All endpoints require `X-Sidecar-Token` (constant-time compare). **[R]** Set `logging.getLogger("pytr").setLevel(WARNING)` — pytr debug-logs the WAF token, login JSON, and WS messages (`api.py:219,231,371`). Never log request bodies.
- `GET /health` (compose healthcheck).
- `POST /pairing/start` `{phone_no, pin}` → `TradeRepublicApi(..., save_cookies=True, cookies_file=<tmpfs>, waf_token="awswaf")`, `initiate_weblogin()`; stash instance by `pairing_id`. → `{pairing_id, countdown_seconds, channel:"push"}`.
- `POST /pairing/resend` `{pairing_id}` → `resend_weblogin()`.
- `POST /pairing/finish` `{pairing_id, code}` → `complete_weblogin(code)`, `save_websession()`, read cookies → `{session_blob}` (base64 cookies.txt). **[R]** Missing/expired `pairing_id` → `410 PAIRING_EXPIRED` (sidecar restart / TTL).
- `POST /balance` `{session_blob, phone_no}` — **no PIN**. Write blob → per-request **tmpfs** file (`chmod 600`), read-back **before** the `finally` delete. `resume_websession()`:
  - `401/403`/jar-invalid → **409 `SESSION_EXPIRED`**.
  - 5xx / network / WAF failure → **502/503 transient** (Kontor retries, does NOT re-pair).
  - success → `compactPortfolio`+`ticker`+`cash` total (cash-only → securities=0; pick EUR bucket) → `{total, currency, session_blob (refreshed), as_of}`.
- **[R] Timeouts:** the sidecar's own internal deadline is authoritative and returns a clean transient error *before* Rails' read timeout; balance (WAF solve + WSS + N tickers) can take tens of seconds. Image: non-root, pinned `pytr==<exact>`, `websockets>=16,<17`, **no playwright**; one asyncio loop/request; always `await tr.close()`.

### 2. egress-proxy — squid (off-the-shelf image + the conf above) + healthcheck.

### 3. docker-compose + TrueNAS
- `compose.scraper.yml`: `kontor`, `tr-scraper`, `egress-proxy`; networks per Egress section; **`kontor` env `RAILS_ENV=production` + `SOLID_QUEUE_IN_PUMA=true`** [R]; `tr-scraper` mounts a **tmpfs** for the session scratch dir [R]; healthchecks on all three; `depends_on: { egress-proxy: service_healthy, tr-scraper: service_healthy }`; sensible `restart:` policy.
- Rails env: `SCRAPER_SIDECAR_URL=http://tr-scraper:8000`, `SCRAPER_SIDECAR_TOKEN`.
- `docs/trade-republic.md`: TrueNAS Custom-App setup, the two-domain allowlist rationale, the credential/2FA flow, ToS/maintenance caveats.

### 4. Rails
- **Migration + model** `app/models/trade_republic_credential.rb` — mirror `go_cardless_credential.rb`: `belongs_to :user`, `encrypts :phone_number, :pin, :session_blob`, validate phone/pin. Table: `user_id` **unique** FK, `phone_number`, `pin`, `session_blob:text`, `last_paired_at`. Add `has_one :trade_republic_credential, dependent: :destroy` to `user.rb`.
- **[R] Provider enum (mandatory code change):** add `trade_republic: "trade_republic"` to the `enum :provider` hash at `bank_connection.rb:36`. It's a real AR enum — without the key, `provider="trade_republic"`, `trade_republic?`, and `where(provider: "trade_republic")` all raise. No DB migration (plain string column, default stays `enable_banking`).
- **Sidecar client** `app/services/trade_republic/scraper_client.rb` — Net::HTTP (mirror `go_cardless/client.rb`), `X-Sidecar-Token`, **explicit timeouts > sidecar's internal deadline**. Errors: `TradeRepublic::ApiError` (5xx transient), `TradeRepublic::SessionExpiredError` (409), `TradeRepublic::SidecarUnavailableError` (conn refused). Three distinct outcomes for the UI/logs.
- **Credentials controller**: **[R]** `show` (`credentials_controller.rb:4-15`) is a single render hash, not a `case` — **add a `trade_republic:` key** (`{configured, phone_number_masked}`, never the PIN). `create`/`update` (`:18`,`:40`) are `case`-based → add `when "trade_republic"`. Add `tr_params` mirroring `params.expect(credentials: [...])` (`phone_number`, `pin`).
- **Pairing flow** in `bank_connections_controller.rb` — concrete diffs:
  - `provider_credential` (`:105`) → add `trade_republic` branch.
  - **[R]** `create` (`:18-30`): for `trade_republic`, set synthetic **`institution_id: "trade_republic"` in the build hash BEFORE `bc.save`** (it's `null: false` + `presence` — setting it in the post-save `case` is too late). Then `pair_start`, return `{id, pairing_id, countdown}` (no `redirect_url`). **[R]** Guard one TR connection per user (the `[user_id, institution_id]` index is **not** unique) — reuse/replace any existing TR connection instead of accumulating orphans.
  - new member `POST :confirm_2fa` `{pairing_id, code}` → `pair_finish`, store `session_blob`, mark `authorized`, create the one `Account` (`account_uid:"trade_republic"`), enqueue first balance fetch. On `pair_finish` failure leave retryable with a message (mirror GC `:171-173`); on `410 PAIRING_EXPIRED` → user-facing "code expired, restart pairing."
  - `reconnect` `case` (`:93`) → `trade_republic`: re-run `pair_start`, return `{pairing_id}`.
  - **Both rescue clauses** (`:36`, `:99`) → add `TradeRepublic::ApiError`.
  - `config/routes.rb`: add `post :confirm_2fa` to the `bank_connections` member block.
- **Sync (balance-only)** in `sync_accounts_job.rb`: `when "trade_republic"` → `scraper_client.balance(...)`, update `Account.balance_amount/currency/balance_updated_at`, persist refreshed `session_blob`; **no transactions**. **[R]** Add an explicit, separate `rescue TradeRepublic::SessionExpiredError => e` → `@bc.update!(status:"expired", error_message: REAUTH_MESSAGE)` — it is a *different class* than EB/GC `ApiError`, so the existing rescue (`:22`) and `reauth_required?` (`:37`) will NOT catch it. Transient `TradeRepublic::ApiError`/`SidecarUnavailableError` → don't expire; **[R]** `retry_on TradeRepublic::SidecarUnavailableError, wait: <e.g. 10.minutes>, attempts: 3` (TR-specific; safe since shared job only raises it for TR).
- **Scheduling**: 
  - `SyncAllAccountsJob` (`:5`): query `BankConnection.active.where.not(provider: "trade_republic")` — **do NOT narrow the shared `active` scope** (`bank_connection.rb:41`).
  - new `app/jobs/sync_scraped_balances_job.rb`: `BankConnection.active.where(provider: "trade_republic")`, enqueue each with **jitter** (`wait: rand(0..3600).seconds`); recency guard against duplicate/concurrent fetches per connection. `config/recurring.yml`: daily, **explicit TZ (Europe/Berlin)**.

### 5. Frontend
- **[R] Two distinct backends:** phone/PIN are *stored* via the credentials endpoint (like GC), but *pairing/2FA* goes through `bank_connections` create→`confirm_2fa`. So this is **not** just a `CredentialForm` branch — build a small **Trade Republic pairing modal** (phone+PIN → "Send code" → 4-digit code → connect), holding `pairing_id` transiently, plus a resend option. (Widen `CredentialForm`'s provider union only if reusing its field rendering.)
- **[R]** `AccountsPage.handleReconnect` (`:87`): branch on **`connection.provider`** (available in `connection_json`, `controller:191`; `types.ts`) — `trade_republic` opens the 2FA modal (re-pair); others follow `redirect_url`. The balance/`expired` badge/Reconnect button already render.
- i18n (`en.ts`/`de.ts`): provider name, phone/PIN/code labels, "code sent", "code expired", re-pair prompts. One-line ToS/automation disclaimer.

## Phasing
1. **Sidecar + squid + compose — the egress gate.** Pass the full adversarial audit (proxy-on denied/allowed, proxy-off no-route incl. v6/raw-IP) **and** a real pair+balance+WSS through the proxy with `websockets>=16`, both WAF branches, **plus the two artifacts** (squid access.log host assertion; balance == TR-app figure). **No Rails work until green.**
2. Rails: model/migration, enum key, sidecar client, credentials + pairing + `confirm_2fa`, sync branch (explicit SessionExpired rescue + transient retry), `SyncAllAccountsJob` exclusion, daily job (jitter+TZ).
3. Frontend pairing + re-pair modal + i18n.
4. Tests + docs.
Scalable Capital + easybank reuse the framework later (out of scope).

## Risks & mitigations
- **Egress guarantee** (CRITICAL): the Phase-1 gate proves it (websockets>=16, DNS-via-proxy, IPv6 off, access.log host assertion, env propagation to all clients incl. stdlib `requests`).
- **Balance correctness** (HIGH): use pytr's proven `compactPortfolio+ticker+cash`; gate-verify == app figure; define multi-currency/cash-only.
- **Jobs never run on TrueNAS** (HIGH): compose sets `RAILS_ENV=production` + `SOLID_QUEUE_IN_PUMA=true`; verify the existing 6h job also fires there.
- **WAF solver / dual stacks** (HIGH): validate `verify` AND `mp_verify` live through the proxy; fallback = pre-fetched WAF token for interactive pairing only.
- **Transient vs expired** (MED): only 401/403→expired; 5xx/network→retry, never auto re-pair.
- **Secrets** (MED): PIN only in pairing; tmpfs+chmod600+`finally` delete; pytr logger→WARNING; shared-secret threat model documented (any appnet container w/ token can drive the sidecar — acceptable single-user home; ensure no error/health path echoes token/cookies).
- **TR flagging/SCA** (MED): daily + jitter + persistent cookie; re-pair first-class; periodic 2FA unavoidable by regulation.
- **Supply chain/ToS** (accepted): pin pytr exact; allowlist neutralizes exfiltration; unofficial API may break.

## Verification
1. **Egress gate (Phase 1)**: the 5-point audit + 2 artifacts above — the gate that justifies storing credentials.
2. **rspec**: model spec; `scraper_client` (WebMock: 409→SessionExpired, conn-refused→SidecarUnavailable, 5xx→ApiError); `SyncAccountsJob` TR branch (balance update; **409→expired**; **5xx→NOT expired, retried**); `SyncAllAccountsJob` **excludes** TR; pairing request spec (mock client; incl. PAIRING_EXPIRED); credentials masks phone, never returns PIN. Full suite green.
3. **End-to-end**: Settings → pair TR (phone/PIN → code) → `authorized`, balance on Dashboard total. `SyncScrapedBalancesJob.perform_now` refreshes. Force `SESSION_EXPIRED` → `expired` + Reconnect → 2FA modal re-pairs → restored. Stop the sidecar → connection shows a clear "scraper unavailable" (not "expired").
4. **Frontend**: 2FA modal opens for a `trade_republic` reconnect (not the redirect path).
