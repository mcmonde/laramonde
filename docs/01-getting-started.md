# Getting started (local)

Run the stack on your workstation and serve a Laravel app at `http://<name>.local`.

## Prerequisites

- Linux or macOS with **Docker Engine** and the **Compose plugin v2.23+** (`docker compose version`).
- Git, and SSH access to your app repositories.
- About 4 GB of free RAM for the stack plus one or two apps.

## 1. Clone and configure the stack

```bash
git clone git@github.com:mcmonde/laramonde.git multi-app
cd multi-app
./dock setup
```

`./dock setup`:

- creates `.env` from `.env.example` (mode `600`, gitignored),
- generates strong Postgres/Redis passwords and a Meilisearch master key,
- syncs Scout/Mail settings from `COMPOSE_PROFILES`,
- detects CPU/RAM and writes container limits.

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
| `sites/portal/defaults.env` | Domain, PHP version, DB password, Reverb keys (secrets, mode `600`) |
| `sites/portal/.env.laravel.example` | Values to merge into the Laravel `.env` |
| `nginx/conf.d/sites/portal.conf` | The nginx vhost |
| `apps/portal/` | Where the Laravel code goes |

It also registers the app in `docker-compose.yml` and `postgres/apps.list` and creates the `portal` database/role if Postgres is running.

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
