# Updating Kontor on TrueNAS

Current deployment (verified read-only):

- Checkout: `/mnt/Mirror_SSD/docker-configs/kontor`
- Compose project: `kontor`
- Compose files: `compose.yml`, `compose.build.yml`, `compose.tls.yml`
- Rails service/container: `kontor` / `kontor-kontor-1`
- TrueNAS architecture: `linux/amd64`
- Persistent Rails data: Docker volume `kontor_kontor_storage`

The pairing-modal fix changes only `app/javascript/pages/AccountsPage.tsx`.
Rebuild/recreate **only Rails**, not the scraper services. The frontend is compiled
into the Rails image: copying the TSX file alone does not update the running app.
These commands are instructions; they have not been executed on the server.

## Before updating

Keep the existing `.env`, encrypted Rails credentials, TLS certificates, and all
Docker volumes. Do not regenerate encryption keys or run `down -v`.

On TrueNAS, define the Compose command in a Bash session:

```bash
cd /mnt/Mirror_SSD/docker-configs/kontor
C=(docker compose -p kontor -f compose.yml -f compose.build.yml -f compose.tls.yml)
```

Back up before deploying. For a consistent full storage backup, briefly stop
Rails (including its in-process background workers), archive the storage volume,
and restart it. Choose a backup location with sufficient free space:

```bash
BACKUP="/mnt/Mirror_SSD/docker-configs/kontor-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
chmod 700 "$BACKUP"
cp -a .env config compose*.yml "$BACKUP/"
OLD_IMAGE=$(docker inspect kontor-kontor-1 --format '{{.Image}}')
docker image tag "$OLD_IMAGE" kontor-kontor:before-update
STORAGE=$(docker volume inspect kontor_kontor_storage --format '{{.Mountpoint}}')
"${C[@]}" stop kontor
tar -czf "$BACKUP/storage.tar.gz" -C "$STORAGE" .
"${C[@]}" start kontor
```

Check that the backup succeeded before proceeding. The backup contains secrets;
keep it private. `before-update` is a reusable tag, so choose a dated tag instead
if you need to retain several rollback images.

## Option A — build from source on TrueNAS (simplest now)

The current local fix is **uncommitted**, so `git pull` will not fetch it.
Both checkouts were at the same commit when investigated. Transfer just the fix
from the local project directory:

```bash
scp app/javascript/pages/AccountsPage.tsx \
  root@truenas:/mnt/Mirror_SSD/docker-configs/kontor/app/javascript/pages/AccountsPage.tsx
```

Then, in the TrueNAS Bash session above:

```bash
"${C[@]}" build kontor
"${C[@]}" up -d --no-deps --no-build --pull never kontor
"${C[@]}" ps kontor
"${C[@]}" logs --tail 100 kontor
```

This preserves the existing TLS override, secrets, storage, networks, and running
scrapers. Builds happen while the old container runs; recreation causes a brief
interruption. The entrypoint runs database preparation automatically.

For future committed releases: commit/push the changes intentionally, then use
`git pull --ff-only` in a clean server checkout before the same build/up commands.
The file copied above will be a local modification; reconcile it before pulling.

## Option B — build locally and transfer the image (no registry)

Run locally from the project root:

```bash
TAG=pairing-refresh-$(date +%Y%m%d-%H%M%S)
docker build --platform linux/amd64 -t "kontor-kontor:$TAG" .
docker save "kontor-kontor:$TAG" | ssh root@truenas 'docker load'
printf 'Image tag: %s\n' "$TAG"
```

The build includes the current working-tree fix, even without a commit.
The image also includes `config/credentials.yml.enc`. Its checksum matched the
server's during this investigation. If credentials change later, use the
**server's existing encrypted credentials** in the build context. Never bake
`master.key` or `.env` into the image; `.dockerignore` excludes these.

On TrueNAS, create `compose.image.yml` with the printed tag substituted:

```yaml
services:
  kontor:
    image: kontor-kontor:pairing-refresh-YYYYMMDD-HHMMSS
```

Deploy with that extra override:

```bash
C=(docker compose -p kontor -f compose.yml -f compose.build.yml -f compose.tls.yml -f compose.image.yml)
"${C[@]}" up -d --no-deps --no-build --pull never kontor
"${C[@]}" ps kontor
"${C[@]}" logs --tail 100 kontor
```

Keep `compose.image.yml` in future deployment commands. `--no-build` is important
because the base Compose file still contains `build: .`.

## Option C — build locally, push to a registry, pull on TrueNAS

Use a registry namespace you control (for example your GitHub username). Kontor's
existing release workflow publishes **scrapers**, not the Rails image.

Locally:

```bash
TAG=pairing-refresh-$(date +%Y%m%d-%H%M%S)
IMAGE="ghcr.io/YOUR_GITHUB_USERNAME/kontor:$TAG"
# Authenticate using a token with write:packages; enter it at the password prompt.
docker login ghcr.io -u YOUR_GITHUB_USERNAME
docker build --platform linux/amd64 -t "$IMAGE" .
docker push "$IMAGE"
printf 'Image: %s\n' "$IMAGE"
```

The encrypted-credentials warning in Option B also applies here. Prefer a private
registry package for an instance-specific image.

On TrueNAS, authenticate if the package is private (token with read:packages),
and set `compose.image.yml` to the exact published image:

```yaml
services:
  kontor:
    image: ghcr.io/YOUR_GITHUB_USERNAME/kontor:pairing-refresh-YYYYMMDD-HHMMSS
```

```bash
docker login ghcr.io -u YOUR_GITHUB_USERNAME
C=(docker compose -p kontor -f compose.yml -f compose.build.yml -f compose.tls.yml -f compose.image.yml)
"${C[@]}" pull kontor
"${C[@]}" up -d --no-deps --no-build --pull never kontor
"${C[@]}" ps kontor
"${C[@]}" logs --tail 100 kontor
```

Use immutable, versioned tags rather than overwriting `latest`.

## Verify the fix

Reload the browser after deployment so it loads the new frontend assets. After
Trade Republic's rate limit has cleared:

1. Start an easybank sync and open TR reconnect while easybank is still syncing.
2. The TR modal should remain open with its original pairing state when easybank
   completes. A failed account refresh should show a banner, not remove the modal.
3. Check the scraper log: one `/pairing/start` per deliberate pairing start, not
   another one caused by the account refresh.

```bash
docker logs --since 10m kontor-tr-scraper-1 2>&1 | grep -v 'GET /health'
```

No browser-level automated test was run for this interaction. TypeScript, the
production frontend build, and the Rails suite passed locally.

## Roll back this frontend-only update

Set/create `compose.image.yml` with:

```yaml
services:
  kontor:
    image: kontor-kontor:before-update
```

Then use the four-file Compose command from Option B and run:

```bash
"${C[@]}" up -d --no-deps --no-build --pull never --force-recreate kontor
```

This fix changes no database schema. For future updates with migrations, an image
rollback alone may not suffice; assess database compatibility before rolling back.
