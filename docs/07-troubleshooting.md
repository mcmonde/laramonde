# Troubleshooting

Start with:

```bash
./dock ps                     # which container is unhealthy or restarting
./dock logs <service>         # its logs
docker compose config -q      # does the compose config even parse
```

## nginx crash-loops

`./dock ps` shows `nginx  Restarting`. Check `./dock logs nginx`.

| Log line | Cause | Fix |
|----------|-------|-----|
| `host not found in upstream "<app>-reverb:8080"` | Vhost points at a container that does not exist (Reverb removed for an older Laravel app, or a service was removed) | Remove the `upstream` and the `location` using it from `nginx/conf.d/sites/<app>.conf`, or start the container |
| `host not found in upstream "<other>"` for a server-only service (admin UI, Komodo…) | That container is stopped/removed | Start it, or delete its `.conf` |
| `cannot load certificate key … Permission denied` | Private keys not readable by unprivileged nginx (UID 101), often after `docker compose down`/re-creation | `./scripts/tls-fix-certs.sh` then `./dock up nginx` |
| `cannot load certificate … No such file` | vhost references a certificate that was never issued | `./dock tls:issue <app>` or `./dock tls:disable <app>` |

Always test before reloading: `docker compose exec nginx nginx -t`.

## A setting change has no effect

- Root `.env` / `sites/<app>/defaults.env` changes need `./dock up --force-recreate <services>` — `restart` keeps the old environment.
- A key in `sites/<app>/defaults.env` that also exists in the root `.env` is ignored (root wins). That is why per-app PHP uses `APP_PHP_VERSION`.
- Container environment beats `apps/<app>/.env`. If `DB_*`, `MAIL_*`, `SCOUT_DRIVER`, `APP_URL`… "won't change", look at the `environment:` block in `sites/<app>/compose.yml` ([who wins](03-apps.md#environment-files-who-wins)).
- Cached config: `./dock artisan <app> optimize:clear`; Octane apps also need `octane:reload` or a restart.

Inspect what a container really sees:

```bash
docker compose exec <app>-php env | sort
./dock artisan <app> tinker --execute="dump(config('database.connections.pgsql.host'))"
```

## `429 Too Many Requests`

Find out who answers:

```bash
curl -s -D - -o /dev/null -X POST https://app.example.com/api/login | grep -i -E '^(HTTP|x-ratelimit|retry-after|server)'
```

- **`X-RateLimit-Limit: 0`** — the route uses `throttle:<name>` but no `RateLimiter::for('<name>')` is defined. Laravel then casts the name to `0` and allows one request per minute per IP. Define the limiter in `RouteServiceProvider::configureRateLimiting()` (Laravel ≤10) or `AppServiceProvider::boot()` (11+):

  ```php
  RateLimiter::for('login', fn (Request $r) =>
      Limit::perMinute(5)->by(strtolower((string) $r->input('email')).'|'.$r->ip()));
  ```

- **No `X-RateLimit-*` headers** — nginx's per-IP limit (20 r/s, burst 40). Raise `burst` in `nginx/conf.d/sites/<app>.conf` and reload nginx ([rate limits](03-apps.md#domains-and-rate-limits)).

## Mail is not sent

1. **Injected mail settings.** With no `dev`/`mail` profile the stack injects `MAIL_MAILER=log`. Remove `MAIL_*` from `sites/<app>/compose.yml` for apps that use a real SMTP/API provider ([details](03-apps.md#mail-and-app-name-are-injected)).
2. **Queued mailables.** `ShouldQueue` mailables wait in Redis until `<app>-queue` sends them. Check the worker is up, `./dock artisan <app> queue:failed`, and run `queue:restart` after deploys.
3. **Network.** Test from **inside** the app container, not the host — hosts often resolve SMTP servers to IPv6 first and time out, which looks like a block:

   ```bash
   docker compose exec <app>-php php -r 'var_dump((bool) @fsockopen("smtp.gmail.com", 587, $e, $m, 8), $m);'
   ```

   If this fails too, the provider is blocking outbound SMTP: ask them to lift it or use an HTTP API mail driver.
4. **Credentials.** Gmail needs an *App Password*; changing the account password revokes it. Gmail also limits volume (~500/day per account).

## Search returns nothing / Scout errors

| Symptom | Fix |
|---------|-----|
| `scout.driver` is `null` | Add `search` to `COMPOSE_PROFILES`, `./dock setup`, `--force-recreate` |
| *Please install the suggested Meilisearch client* | `./dock composer <app> update meilisearch/meilisearch-php --with-dependencies`; commit `composer.lock` |
| Index empty | `./dock artisan <app> scout:import "App\Models\X"` |
| *Attribute is not filterable* | `./dock artisan <app> scout:sync-index-settings` |

## Containers show `unhealthy` but work

Queue, scheduler and Reverb containers inherit the PHP image's healthcheck, which probes the FPM/Octane port they never open. Override it per service in `sites/<app>/compose.yml`:

```yaml
  myapp-queue:
    <<: *app
    command: ${APP_QUEUE_COMMAND:-php artisan queue:work --sleep=3 --tries=3 --max-time=3600}
    healthcheck:
      test: ["CMD-SHELL", "grep -q queue:work /proc/1/cmdline"]
      interval: 30s
```

## Permission denied inside an app

- App containers run as UID/GID `1000` (`APP_UID`/`APP_GID`). Fix ownership on the host: `chown -R 1000:1000 apps/<app>/storage apps/<app>/bootstrap/cache`.
- Containers run with `cap_drop: ALL`, so even root inside cannot write files owned by another user. Run one-off commands as the app user: `docker compose exec --user 1000:1000 <app>-php …` (e.g. creating a Python venv inside `apps/<app>`).
- `git` refuses with *dubious ownership* when run as root on `apps/<app>`: use `git -c safe.directory='*' …` instead of changing global git config.

## `./dock new-app` aborts with "Non-interactive session: treating as NO"

The capacity check needs confirmation. After reviewing `./dock resources`, run `RESOURCES_ASSUME_YES=1 ./dock new-app …` (or `--force`).

## Generated URLs contain `/api/api/…`

SPA layout sets `APP_URL=https://<domain>/api`. If routes already carry an `api` prefix and the app forces the root URL, set `APP_URL` to the origin ([SPA section](03-apps.md#spa--api-on-one-domain)).

## Restoring a dump fails with `role "…" does not exist`

The dump was made by a different database user. Restore with `pg_restore --no-owner --no-acl` (custom format) or strip `OWNER TO`/`GRANT` lines from a plain SQL file ([how](04-migrating-an-app.md#4-copy-the-database)).

## `git pull` on a server refuses to overwrite local changes

Something was patched in place on that server. Inspect with `git diff`; if the change is already upstream, discard it (`git checkout -- <file>`) and pull again.
