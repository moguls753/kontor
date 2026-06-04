# Distribution & self-hosting plan

How Kontor is packaged so other people can self-host it with minimal friction.

## Distribution model (decided)

- **kontor (Rails) = from SOURCE.** Operators `git clone` and `docker compose up
  -d --build`. The Rails app keeps the idiomatic **encrypted-credentials** secrets
  model (each operator generates their *own* `master.key` + credentials). Building
  a Rails app locally is fast and standard, and it avoids baking the maintainer's
  secrets into a shipped image.
- **Sidecars (`tr-scraper`, `easybank-scraper`) = pre-built IMAGES** on GHCR.
  These are the painful builds — `easybank-scraper` bakes CloakBrowser's ~200 MB
  patched Chromium — and they carry **no secrets** (the sidecar token arrives via
  ENV at runtime), so they are clean to publish. Operators *pull* them.
- **Egress proxies** stay `ubuntu/squid:latest` + the repo's `egress-proxy/*.conf`
  (the security allowlists ship with the clone, so they stay auditable).

This split is why both earlier blockers dissolve: credentials work (source has
Rails), and the squid confs are present (repo clone).

## Verified facts (doublecheck against the repo)

- GHCR owner = **`moguls753`** (`github.com:moguls753/kontor`). Images:
  `ghcr.io/moguls753/kontor-tr-scraper`, `ghcr.io/moguls753/kontor-easybank-scraper`.
- Sidecars build standalone from `./scraper` / `./easybank-scraper`; no secrets baked.
- CI (`.github/workflows/ci.yml`) runs brakeman / bundler-audit / importmap-audit /
  rubocop, plus (added by this change) a `test` job (rspec) and a `sidecar-test` job
  (pytest). Untracking `credentials.yml.enc` does not break CI:
  `config/environments/test.rb` supplies deterministic, non-secret test keys so the
  suite runs without a master.key.
- `config/master.key` is already untracked; only `config/credentials.yml.enc` is
  tracked → untrack exactly one file.
- kontor's Dockerfile builds assets with `SECRET_KEY_BASE_DUMMY=1` (build needs no
  real secret) but `COPY . .` **bakes** `credentials.yml.enc` → the operator must
  create their own credentials **before** building.
- No ENV wiring for `SECRET_KEY_BASE` / AR-encryption is needed for production
  (credentials path). It is only useful for a CI test job (Phase 5).
- `easybank-scraper` image is likely **amd64-only** (CloakBrowser bakes its
  Chromium per-arch); `tr-scraper` is multi-arch-capable. arm64 operators build
  the sidecar locally via `compose.build.yml`.

## Decisions (confirmed)

1. **easybank-scraper arch:** **amd64-only**; arm64 → local build (CloakBrowser
   ships no arm64 Chromium).
2. **CI test job:** included — rspec + pytest gate the suite.

## Plan

> **Status:** Phases 1–5 below are **implemented** in this change (compose split,
> credentials untracked, `release.yml`, CI rspec/pytest jobs, docs). What remains
> is the manual **"Before going public"** steps at the bottom (rotate secrets,
> purge history, publish + make the GHCR packages public).

### Phase 1 — Compose split
- `compose.yml`: sidecars → `image: ghcr.io/moguls753/kontor-{tr,easybank}-scraper:vX.Y.Z`
  (drop their `build:`); kontor keeps `build: .`.
- New `compose.build.yml`: re-adds `build: ./scraper` + `build: ./easybank-scraper`
  for maintainer/CI/arm64 use.
- Keep the squid `./egress-proxy/*.conf` bind-mounts.
- **Verify:** `docker compose config`; `up -d --build` builds only kontor and
  *pulls* the sidecars; `-f compose.yml -f compose.build.yml build` builds sidecars.

### Phase 2 — Credentials hygiene (Rails way)
- `git rm --cached config/credentials.yml.enc`; add to `.gitignore` (maintainer's
  local copy stays; operators generate fresh — no key conflict, no git-pull restore).
- Update `.env.example`: `RAILS_MASTER_KEY` = the operator's *own* generated key.
- Operator order: `git clone` → create `.env` with the sidecar tokens FIRST (Compose
  needs them for every command) → generate own credentials (`credentials:edit`,
  `db:encryption:init`, a second `credentials:edit` to paste the AR keys) → set
  `RAILS_MASTER_KEY` → `docker compose up -d --build` (bakes creds; migrations run
  automatically via the entrypoint's `rails db:prepare`).

### Phase 3 — Publish workflow (`.github/workflows/release.yml`)
- Trigger on tag `v*`: GHCR login (`GITHUB_TOKEN`, `packages: write`), buildx push
  the **two sidecars** — `tr-scraper` multi-arch (amd64+arm64), `easybank-scraper`
  amd64. Versioned tag `:vX.Y.Z` only (no floating `:latest`). No Rails image, no
  asset precompile, no secrets.
- Bump the pinned sidecar tag in `compose.yml` per release.

### Phase 4 — Docs
- README "Self-hosting" quickstart (clone → `.env` → own credentials → `up -d
  --build` → connect banks); arm64 / unpublished-tag note (build the sidecars).
- Align `docs/easybank.md` deploy section: sidecars are *pulled*, not built.

### Phase 5 — Harden CI
- `test` job runs `rspec`; `sidecar-test` runs both sidecars' `pytest` (easybank +
  tr-scraper). `config/environments/test.rb` provides deterministic, non-secret
  `secret_key_base` + AR-encryption keys so the suite runs without a master.key
  (production keeps using credentials).

### Verify gate per phase
`docker compose config` resolves · a local sidecar build succeeds · a dry `up`
pulls the sidecars · rspec + pytest stay green.

## Operator: generating your own credentials

Kontor ships no secrets — on first setup you create your own Rails master key +
credentials (holding `secret_key_base` + the ActiveRecord encryption keys). Both
`config/master.key` and `config/credentials.yml.enc` are gitignored (yours, never
committed). The Docker build bakes *your* `credentials.yml.enc`; `master.key` is
supplied at runtime via `RAILS_MASTER_KEY`.

**Order matters — `.env` FIRST.** Compose evaluates the `${...:?}` sidecar-token
guards for *every* command, so `docker compose` aborts without them. Create `.env`
and set the two tokens before any compose command:

```bash
cp .env.example .env
# set SCRAPER_SIDECAR_TOKEN and EASYBANK_SIDECAR_TOKEN (each: openssl rand -hex 32);
# leave RAILS_MASTER_KEY blank for now.
```

**With Ruby (contributors / source users):**

```bash
bundle install
EDITOR=nano bin/rails credentials:edit     # writes config/master.key + credentials.yml.enc
bin/rails db:encryption:init               # prints the 3 AR-encryption keys
EDITOR=nano bin/rails credentials:edit     # paste them (a SECOND edit) under:
#   active_record_encryption:
#     primary_key: ...
#     deterministic_key: ...
#     key_derivation_salt: ...
```

**Docker only (no local Ruby):** generate inside the kontor image, bind-mounting
`config/` so the files land on the host (`.env` with the two tokens must already
exist — see above):

```bash
docker compose build kontor   # builds without creds yet — that's fine, see the rebuild below
docker compose run --rm --no-deps -v "$PWD/config:/rails/config" -e EDITOR=nano \
  kontor bin/rails credentials:edit                          # -> master.key + credentials.yml.enc on host
docker compose run --rm --no-deps kontor bin/rails db:encryption:init   # prints the 3 keys
docker compose run --rm --no-deps -v "$PWD/config:/rails/config" -e EDITOR=nano \
  kontor bin/rails credentials:edit                          # paste the 3 keys (SECOND edit)
```

The `active_record_encryption` keys are **MANDATORY** — without them the app boots
but saving any bank credential fails at runtime.

Finally put the contents of `config/master.key` into `.env` as `RAILS_MASTER_KEY`,
then bring the stack up: **`docker compose up -d --build` (re)builds kontor so your
`credentials.yml.enc` is baked in** — running plain `up -d` would ship an image
without it.

## Publishing (going public)

**Make the sidecar images pullable.** Push a `v*` tag (runs `release.yml`, which
builds + pushes the two sidecar images), then set **both** GHCR packages to
**public** (GitHub → your profile → Packages → each package → Package settings →
Change visibility). Until that is done, `docker compose up` can't pull them and
operators must use the build override
(`-f compose.yml -f compose.build.yml up -d --build`).

**Secrets in history (optional hardening).** `config/credentials.yml.enc` stays in
git history after `git rm --cached`, but it is **AES-encrypted** — only your
`config/master.key` (which is never committed) can read it. That is the standard,
intended Rails model: publishing the repo does **not** expose the secrets, as long
as the master.key stays private (keep it out of git and out of logs/CI output). If
you want belt-and-suspenders — it would only matter if the master.key ever leaked —
rotate the secrets the file held (GoCardless keys, `secret_key_base`, AR-encryption
keys) and purge it from history
(`git filter-repo --path config/credentials.yml.enc --invert-paths`) before going
public. Not required for the standard model.
