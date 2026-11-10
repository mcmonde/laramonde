# Getting started (local)

Run the stack on your workstation and serve a Laravel app at `http://<name>.local`.

## Prerequisites

- Linux or macOS with **Docker Engine** and **Docker Compose v2.20+** (`docker compose version`). v2.23+ is what makes `deploy.resources.limits` apply on `docker compose up`.
- Git, and SSH access to your app repositories.
- On the host: `openssl` (`./dock setup` secrets) and `sha256sum` (every `./dock new-app` Redis ACL). macOS needs GNU `sha256sum` on `PATH`. `python3` is required for `./dock scan-app` and for `./dock new-app` while the `search` profile is on. `curl` is how setup detects a public IPv4 for the backup prefix; setup continues when detection fails.
- About 4 GB of free RAM for the stack plus one or two apps.

## 1. Clone and configure the stack

```bash
git clone git@github.com:mcmonde/laramonde.git multi-app
cd multi-app
./dock setup
```

`./dock setup`:

- creates `.env` from `.env.example` when `.env` is absent (mode `600`, gitignored). An existing `.env` is kept, and only weak secrets are replaced,
- replaces a weak Postgres or Redis password with a **96-char hex** value, and a weak Meilisearch master key with a **64-char hex** value,
- sets `APP_UID` and `APP_GID` to the user running setup. A setup run as root leaves the example values `1000` and `1000`. A later `./dock setup` as another user rewrites those two keys,
- syncs Scout/Mail settings from `COMPOSE_PROFILES`,
- sets `BACKUP_S3_PREFIX=database-backups/<ipv4>` when the prefix is empty and a public IPv4 can be detected,
- detects CPU/RAM and runs resource apply to write container limits. Setup still finishes when that apply fails; run `./dock resources apply` again after reading the message.

The local default is `COMPOSE_PROFILES=dev,search`, which adds the **workspace** container, **Mailpit** (catches outgoing mail) and **Meilisearch**.

Start the shared services:

```bash
./dock up
./dock ps
```

## 2. Add an app

```bash
./dock scan-app ../portal          # optional: what PHP version, extensions and flags it needs
./dock new-app portal portal.local
```

Options you may need (details in [Managing apps](03-apps.md)):

| Option | Effect |
|--------|--------|
| `--php 8.3` | PHP version for this app (8.1–8.5). Default: `PHP_VERSION` in `.env` |
| `--octane` | Laravel Octane (Swoole) instead of PHP-FPM |
| `--spa` | `/` serves a built SPA, `/api` goes to Laravel |
| `--php-ext "imagick"` / `--apt "ghostscript"` | Extensions/packages only this app needs (app-specific image tag) |

This creates:

| Path | What it is |
|------|------------|
| `sites/portal/compose.yml` | The app's containers (`portal-php`, `portal-queue`, `portal-scheduler`, `portal-reverb`) |
| `sites/portal/defaults.env` | Domain, PHP version, DB password, Redis ACL password, Reverb keys, Meilisearch key when `search` is on (secrets, mode `600`) |
| `sites/portal/.env.laravel.example` | Values to merge into the Laravel `.env` |
| `nginx/conf.d/sites/portal.conf` | The nginx vhost |
| `apps/portal/` | Where the Laravel code goes |

It also registers the app in `docker-compose.yml` and `postgres/apps.list`, writes Redis ACL user `app:portal` (keys `portal_*`) to `redis/acl/apps.acl`, and creates the `portal` database and role when Postgres is already running. With `search` in `COMPOSE_PROFILES` (the local default), it asks Meilisearch for a key limited to `portal_*` indexes and exits before writing the app when that request fails. Meilisearch is started for the key request if it is not already up.

## 3. Put the code in place

`apps/portal/` already contains a `.gitkeep`, so clone elsewhere and copy in:

```bash
git clone git@github.com:org/portal.git /tmp/portal
rsync -a /tmp/portal/ apps/portal/
rm -rf /tmp/portal
```

## 4. Configure Laravel

```bash
cp apps/portal/.env.example apps/portal/.env   # if the repo has one
```

Merge the values from `sites/portal/.env.laravel.example` into `apps/portal/.env` (DB, Redis, mail, Reverb). Note that the stack also **injects** many of these as container environment variables, which take precedence over `apps/portal/.env` — see [Environment files](03-apps.md#environment-files-who-wins).

## 5. Start and initialise

```bash
echo "127.0.0.1 portal.local" | sudo tee -a /etc/hosts
./dock up
./dock composer portal install
./dock artisan portal key:generate
./dock artisan portal migrate
./dock artisan portal storage:link
```

Open <http://portal.local>. Mail sent by the app shows up in Mailpit at <http://127.0.0.1:8025>.

## Everyday commands

```bash
./dock artisan portal tinker            # artisan in the app's PHP container
./dock composer portal require foo/bar  # composer in the app's PHP container
./dock workspace                        # shell with php, composer, node, git (dev profile)
./dock logs portal-php                  # follow logs of one service
./dock restart portal-queue             # restart a worker
./dock ps                               # status of everything
./dock down                             # stop the stack (data volumes are kept)
```

## Next

- Adding more apps, PHP versions, Octane/SPA: [Managing apps](03-apps.md)
- Going live: [Production server](02-production.md)
