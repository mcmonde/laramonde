# Managing apps

## Scan the repo first

Before `new-app`, check what the app needs:

```bash
./dock scan-app git@bitbucket.org:team/api.git --branch dev   # or a local path
```

It reports the Laravel version, which PHP versions `composer.lock` allows, Octane/SPA/Reverb/queue/scheduler/Meilisearch needs, **PHP extensions missing from the shared image**, system packages some libraries need (wkhtmltopdf, Ghostscript, Chromium, ffmpeg, …), and heavy packages that are installed but never referenced in the app's code. It ends with a suggested `new-app` command.

When the shared image for that PHP version is built, the extension check runs Composer inside it (`check-platform-reqs`, or a dry-run resolve when there is no `composer.lock`), so transitive requirements are caught too. Otherwise it falls back to reading the Dockerfile. `--no-docker` forces the static scan.

## Creating an app

```bash
./dock new-app <name> [domain] [--octane] [--spa] [--php X.Y]
               [--php-ext "a b"] [--apt "x y"] [--force] [--skip-scale]
```

| Argument | Notes |
|----------|-------|
| `<name>` | Lowercase letters, digits, hyphens. The database and role become `<name>` with `-` → `_` |
| `[domain]` | Defaults to `<name>.local`. Change later in `sites/<name>/defaults.env` (`APP_DOMAIN`) + `./dock site:render <name>` |
| `--php X.Y` | 8.1–8.5. Default: `PHP_VERSION` in `.env` |
| `--php-ext "a b"` | Extra PHP extensions for this app only ([per-app extras](#per-app-extensions-and-packages)) |
| `--apt "x y"` | Extra Debian packages for this app only |
| `--octane` | Swoole HTTP server (`<name>-octane`, port 8000) instead of PHP-FPM (`<name>-php`, port 9000) |
| `--spa` | `/` → `apps/<name>/frontend/dist`, `/api` → Laravel, `/app` → Reverb |
| `--force` | Create even when the capacity check fails |
| `--skip-scale` | Skip the capacity check and rescale |

If Postgres was initialised before the app existed and the database is missing: `./dock db:create <name>`.

## Containers per app

| Service | Command | Notes |
|---------|---------|-------|
| `<app>-php` or `<app>-octane` | PHP-FPM / `octane:start` | Serves HTTP via nginx |
| `<app>-queue` | `queue:work` (`APP_QUEUE_COMMAND`) | Needed if anything is queued (mailables with `ShouldQueue`, jobs, Scout with `SCOUT_QUEUE=true`) |
| `<app>-scheduler` | `schedule:work` | Runs `app/Console/Kernel` / `routes/console.php` schedules |
| `<app>-reverb` | `reverb:start` | Laravel 11+ only |

Remove services an app does not need by deleting them from `sites/<app>/compose.yml` (see [older Laravel](#older-laravel-versions-810)).

## Per-app PHP versions

Each app's PHP version lives in `sites/<app>/defaults.env`:

```env
APP_PHP_VERSION=8.3
```

The key is deliberately **not** `PHP_VERSION`: the root `.env` value wins over per-app files for the same key, so `PHP_VERSION` there would be ignored. Apps created before `APP_PHP_VERSION` existed fall back to the root `PHP_VERSION`.

Change an existing app:

```bash
# edit sites/portal/defaults.env → APP_PHP_VERSION=8.3
./dock build portal-php
./dock up --force-recreate portal-php portal-queue portal-scheduler portal-reverb
./dock artisan portal --version
```

Images are tagged by version (`multiapp-php:8.3`, `multiapp-php-octane:8.4`), so apps on the same version share one image.

## Per-app extensions and packages

`php-fpm/Dockerfile` and `php-octane/Dockerfile` hold only what most Laravel apps need, because every app on that PHP version is built from them. Anything one app needs goes into that app's settings instead:

```bash
./dock extras hcdcresearch --php-ext imagick --apt ghostscript   # set (or use --php-ext/--apt on new-app)
./dock extras hcdcresearch                                       # show
./dock extras hcdcresearch --clear                               # back to the shared image
./dock up --build --force-recreate hcdcresearch-php hcdcresearch-queue hcdcresearch-scheduler
docker compose exec nginx nginx -s reload                        # containers got new IPs
```

This writes `APP_PHP_EXTENSIONS`, `APP_APT_PACKAGES` and `APP_IMAGE_SUFFIX` to `sites/<app>/defaults.env`. The app then builds its own tag (`multiapp-php:8.4-hcdcresearch`) from the same Dockerfile; the extras step is the last layer, so everything above it is the identical, shared layer and the app image only costs its extras on disk. Apps without extras keep using the plain shared image.

- PHP extension names are [install-php-extensions](https://github.com/mlocati/docker-php-extension-installer#supported-php-extensions) names (`imagick`, `soap`, `ldap`, `mongodb`, …).
- When ImageMagick is installed, its PDF/PS policy is relaxed automatically (needed by `spatie/pdf-to-image`; add `ghostscript` too).
- Apps created before this feature: `./dock extras` upgrades their `sites/<app>/compose.yml` (backup `compose.yml.bak-extras`).
- Prefer removing a package the app never uses over adding extras for it — `scan-app` flags those.

## Octane

```bash
./dock new-app api api.example.com --octane
./dock composer api require laravel/octane
./dock artisan api octane:install --server=swoole
```

Workers, task workers and max requests are in `sites/<app>/defaults.env` (`OCTANE_*`, `OCTANE_COMMAND`). After deploying code, reload workers: `./dock artisan api octane:reload` (or restart `api-octane`).

## SPA + API on one domain

```bash
./dock new-app portal portal.example.com --spa
git clone <api-repo> /tmp/portal-api && rsync -a --exclude frontend/ /tmp/portal-api/ apps/portal/ && rm -rf /tmp/portal-api
git clone <spa-repo> apps/portal/frontend
cd apps/portal/frontend && npm ci && npm run build      # outputs dist/, Vite base must be "/"
```

nginx sends `/api/*`, `/sanctum/*`, `/broadcasting/*` and `/up` to Laravel and everything else to `frontend/dist` (with `index.html` fallback).

`APP_URL` is set to `https://<domain>/api`. If the Laravel routes **already** include an `api/...` prefix (for example `Route::prefix('api/v1')`) and the app calls `URL::forceRootUrl(config('app.url'))`, generated URLs come out as `/api/api/v1/...`. In that case set `APP_URL` to the site origin (`https://<domain>`) in both `sites/<app>/defaults.env` and `apps/<app>/.env`, then recreate the app containers.

## Older Laravel versions (8–10)

The templates target Laravel 11+. For older apps:

1. **No Reverb.** Delete the `<app>-reverb` service from `sites/<app>/compose.yml`, and remove the `upstream <app>_reverb { … }` block and the `location /app { … }` block from `nginx/conf.d/sites/<app>.conf`. Otherwise nginx fails with `host not found in upstream "<app>-reverb:8080"`. Re-apply after every `./dock site:render` or `./dock tls:issue`, which regenerate the vhost from the template.
2. **Cache key.** Laravel ≤10 reads `CACHE_DRIVER`, not `CACHE_STORE`. Set `CACHE_DRIVER` in the container environment or the app `.env`.
3. **Broadcasting.** Remove `BROADCAST_CONNECTION` / `REVERB_*` from the container environment if the app uses another driver.
4. **PHP.** Laravel 8 officially supports PHP ≤ 8.1, but most Laravel 8 apps run on 8.2/8.3 once `composer.lock` resolves. Match what production already runs (`--php 8.3`), and check `composer.lock` for packages requiring `php >= 8.2`.

## Environment files: who wins

| File | Read by | Change takes effect after |
|------|---------|---------------------------|
| `.env` (root) | Compose interpolation for **all** services; helper scripts | `./dock up --force-recreate <services>` (a restart is not enough). `BACKUP_*` only: nothing — read on the next `./dock backup` |
| `sites/<app>/defaults.env` | Compose interpolation for that app only; **loses** to root `.env` on the same key | `./dock up --force-recreate <app services>` |
| `environment:` in `sites/<app>/compose.yml` | Becomes real env vars inside the containers | `--force-recreate` |
| `apps/<app>/.env` | Laravel | `./dock artisan <app> config:clear` and restart the app's containers (Octane always needs a restart/reload) |

Laravel never overwrites an environment variable that already exists, so **container environment beats `apps/<app>/.env`**. The template injects: `APP_URL`, `APP_NAME`, `DB_*`, `REDIS_*`, `CACHE_STORE`, `SESSION_DRIVER`, `QUEUE_CONNECTION`, `SCOUT_*`, `MEILISEARCH_*`, `MAIL_MAILER/HOST/PORT`, `BROADCAST_CONNECTION`, `REVERB_*`.

### Mail and app name are injected

`MAIL_MAILER`/`MAIL_HOST`/`MAIL_PORT` come from the root `.env`, which `./dock setup` sets to `log` when neither `dev` nor `mail` profile is on. An app that sends real mail (Gmail, SES, Mailgun…) must not get those overrides:

- remove `APP_NAME`, `MAIL_MAILER`, `MAIL_HOST`, `MAIL_PORT` from the `environment:` block of `sites/<app>/compose.yml`, keep the real values in `apps/<app>/.env`,
- `./dock up --force-recreate <app services>`.

## Deploying code updates

```bash
cd apps/portal && git pull && cd -
./dock composer portal install --no-dev --optimize-autoloader
./dock artisan portal migrate --force
./dock artisan portal optimize          # or config:cache / route:cache
./dock artisan portal queue:restart     # workers pick up new code
./dock artisan portal octane:reload     # Octane apps only
```

Commit `composer.lock` in app repositories. If it is gitignored, a new server installs whatever `composer.json` allows and can miss packages the code expects.

## Domains and rate limits

- Change a domain: edit `APP_DOMAIN` (and `APP_URL`) in `sites/<app>/defaults.env`, `./dock site:render <app>`, `./dock restart nginx`, then `./dock tls:issue <app>`.
- nginx limits each client IP to **20 requests/s with a burst of 40** per vhost (`limit_req zone=app burst=40 nodelay`). Busy SPAs or many users behind one office IP can hit `429`. Raise the burst in `nginx/conf.d/sites/<app>.conf` (for example `burst=200`) and reload nginx; re-apply after `site:render`/`tls:issue`.

## Removing an app

```bash
./dock remove-app portal                               # containers/vhost/include only
./dock remove-app portal --drop-db --remove-code --force   # also DROP DATABASE/ROLE and delete apps/portal
```

Take a backup first: `./dock backup portal`.
