# Kontor

Open-source, self-hostable personal finance manager. Import bank transactions automatically via Open Banking, categorize them with AI assistance, and track your spending — all on your own server.

**Privacy-first**: when using AI categorization, only the remittance text is sent to the LLM — never amounts, balances, or account details.

## Why Kontor?

Most personal finance tools are either closed-source SaaS (your data on someone else's server) or open-source but manual (CSV imports, no bank sync). Kontor gives you both: automatic bank sync via Open Banking APIs and full ownership of your data.

- Connect 2,500+ European banks via Enable Banking or GoCardless
- AI-powered transaction categorization (cloud or local LLMs)
- Self-host on anything that runs Docker — a VPS, a NAS, a Raspberry Pi
- No tracking, no ads, no data sharing

## Features

- **Automatic bank sync** — Connect 2,500+ European banks via Open Banking (Enable Banking or GoCardless). Transactions and balances sync in the background.
- **AI categorization** — Classify transactions using any OpenAI-compatible API, including local models (LM Studio, Ollama, llama.cpp). Only remittance text is sent — never amounts or account details.
- **Transaction management** — Search, filter by account, category, date range. Paginated, responsive.
- **Dashboard** — Total balance, monthly income and expenses, recent transactions at a glance.

## Tech Stack

| Layer | Technology |
|---|---|
| Backend | Ruby on Rails 8, Ruby 3.4 |
| Frontend | React 19 (TypeScript) via `vite_rails` |
| Styling | Tailwind CSS v4 |
| Database | SQLite3 |
| Auth | Session-based (`has_secure_password` + bcrypt) |
| Background Jobs | Solid Queue |
| i18n | English + German (`react-i18next`) |
| Testing | RSpec, factory_bot, faker |
| Deployment | Kamal (Docker) |

## Self-Hosting

### Docker (recommended)

Kontor runs as a small Docker Compose stack: the Rails app plus two egress-locked
scraper sidecars (Trade Republic and easybank/Barclaycard DE) with their proxies.
The **Rails app is built from source** (so you generate your own secrets — nothing
sensitive is baked into a shipped image); the **sidecars run as pre-built amd64
images** from GHCR (build them locally on arm64).

**Requirements:** Docker + Docker Compose. Generating your Rails credentials
(step 3) also needs a bundled Ruby 3.4+ **or** a one-off container — both recipes
are in [docs/distribution.md](docs/distribution.md).

```bash
# 1. Get the repo — it carries the compose files and the egress allowlists
git clone https://github.com/moguls753/kontor.git
cd kontor

# 2. Create .env FIRST — Compose needs the sidecar tokens for EVERY command
cp .env.example .env
#   set SCRAPER_SIDECAR_TOKEN  and  EASYBANK_SIDECAR_TOKEN  (each: openssl rand -hex 32)
#   leave RAILS_MASTER_KEY blank for now

# 3. Generate your OWN Rails secrets (the repo ships none). Needs Ruby + gems;
#    no local Ruby? use the container recipe in docs/distribution.md instead.
bundle install
bin/rails credentials:edit       # creates config/master.key + credentials.yml.enc
bin/rails db:encryption:init     # prints 3 ActiveRecord encryption keys
bin/rails credentials:edit       # paste them under an  active_record_encryption:  block
#   ⚠ those encryption keys are REQUIRED — without them, saving any bank
#     credential fails at runtime.
#   Then set RAILS_MASTER_KEY in .env to the contents of config/master.key.

# 4. Launch — builds the Rails app (baking your credentials), starts the stack,
#    runs migrations
docker compose up -d --build
```

Kontor is then at `http://localhost:3000`. SQLite data and the trusted-device
scraper profile persist in named volumes across restarts.

> **Sidecar images:** the `docker compose up` pull path needs the sidecar images
> published to GHCR **and** set public (via a `v*` release — see
> [docs/distribution.md](docs/distribution.md)). On **arm64**, or before a public
> release exists, build the sidecars from source instead:
> `docker compose -f compose.yml -f compose.build.yml up -d --build`

### From source (development)

If you want to contribute or run from source:

**Requirements:** Ruby 3.4+, Node.js 20+, SQLite3

```bash
git clone https://github.com/moguls753/kontor.git
cd kontor
bundle install
npm install
bin/rails db:setup
bin/dev  # Starts Rails + Vite together
```

The app will be available at `http://localhost:3000`.

### Production with Kamal

Kontor includes a `config/deploy.yml` for [Kamal](https://kamal-deploy.org/) deployments. Set `RAILS_MASTER_KEY` in `.kamal/secrets` and update the server IP in `deploy.yml`.

### Running Tests

```bash
bundle exec rspec
```

## Banking Providers

Kontor supports two Open Banking providers. You only need one.

| Provider | Coverage | Setup |
|---|---|---|
| [Enable Banking](https://enablebanking.com) | 2,500+ European banks | App ID + RSA private key |
| [GoCardless](https://gocardless.com/bank-account-data/) | 2,400+ European banks | Secret ID + Secret key |

Configure credentials in Settings, then connect your bank through the in-app flow. The OAuth redirect handles the rest.

## AI Categorization

Transaction categorization works with any LLM provider:

- **Cloud**: Google Gemini (default), or any OpenAI-compatible API
- **Local**: LM Studio, Ollama, llama.cpp server, or any tool that exposes an OpenAI-compatible endpoint

Only the remittance text (e.g., "REWE MARKT BERLIN") is sent to the model. Amounts, IBANs, balances, and account details never leave your server.

## Roadmap

- [x] Authentication (signup, login, sessions)
- [x] Design system (Soft Brutalist + Warm Tones + Teal Accent)
- [x] i18n (English + German)
- [x] Bank account integration (Enable Banking + GoCardless)
- [x] Transaction import, filtering, and pagination
- [x] Account management with sync and status tracking
- [x] Category management (CRUD)
- [x] Credential management and bank connection OAuth flow
- [x] Dashboard with live balances and recent transactions
- [ ] AI-powered categorization (Gemini + local LLM support)
- [ ] Recurring transaction detection
- [ ] Spending statistics and charts
- [ ] CSV/MT940 import
- [ ] Multi-currency support
- [ ] Mobile app (or PWA)

## Contributing

Contributions are welcome. Please open an issue first to discuss what you'd like to change.

## License

[MIT](LICENSE)
