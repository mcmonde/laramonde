# Production server

From a fresh server to apps served over HTTPS, with certificate renewal, nightly backups and failure alerts.

## 1. Prepare the server

- **OS:** Ubuntu/Debian with a public IPv4.
- **Docker:** Docker Engine + Compose plugin **v2.23+**.
- **Firewall:** allow inbound `22`, `80`, `443`. Nothing else needs to be public — Postgres, Redis and Meilisearch stay on Docker's internal network.
- **DNS:** create an `A` record for every app domain pointing at the server **before** issuing certificates.
- **Swap on small droplets:** on 1–2 GB RAM hosts add a 2 GB swap file; Composer and Meilisearch indexing spike memory.
- **Outgoing mail:** some providers (including DigitalOcean on newer accounts) block outbound SMTP. Test from inside an app container before go-live — see [Troubleshooting → mail](07-troubleshooting.md#mail-is-not-sent).

## 2. Install the stack

```bash
mkdir -p /home/www && cd /home/www
git clone git@github.com:mcmonde/laramonde.git laramonde
cd laramonde
cp .env.example .env
```

Edit `.env` before running setup:

```env
COMPOSE_PROFILES=tls            # add ,search if any app uses Meilisearch
NGINX_BIND=0.0.0.0              # listen on the public interface
CERTBOT_EMAIL=you@company.com
CERTBOT_STAGING=0               # real certificates
MEILI_ENV=production            # only matters with the search profile
RESOURCE_MODE=unlimited         # small hosts; use auto on larger ones
```

Then:

```bash
./dock setup
./dock up
```

`./dock setup` also fills `BACKUP_S3_PREFIX=database-backups/<public-ipv4>` so each server's backups land in their own folder.

### Resource modes

- `auto` — Docker CPU/RAM limits per container, calculated from the host. `./dock new-app` refuses apps that do not fit.
- `unlimited` — no cgroup caps; capacity problems become warnings. Practical on 1–4 GB droplets; the kernel OOM killer is the only safety net, so keep swap.

`./dock resources` shows the current assessment; `./dock resources apply` rewrites limits after changes.

## 3. Add each app

```bash
./dock new-app crm crm.example.com --octane --php 8.4
```

Non-interactive sessions treat the capacity prompt as "no". When you have checked the host, confirm with:

```bash
RESOURCES_ASSUME_YES=1 ./dock new-app crm crm.example.com
```

Deploy the code, merge the Laravel env, migrate — same as [Getting started](01-getting-started.md#3-put-the-code-in-place). For an app that already exists elsewhere, follow [Migrating an existing app](04-migrating-an-app.md).

## 4. HTTPS

```bash
./dock tls:issue crm
```

This checks the domain is public, starts nginx, requests a Let's Encrypt certificate through the HTTP-01 webroot, fixes key permissions for the unprivileged nginx, switches the vhost to HTTPS, sets `APP_TLS=1` and `APP_URL=https://…` in `sites/crm/defaults.env`, and starts the certbot renew loop.

```bash
./dock tls:certs        # all certificates + days remaining
./dock tls:status crm   # vhost/TLS state of one app
./dock tls:renew        # renew, fix permissions, reload nginx
./dock tls:disable crm  # back to HTTP-only
```

After `tls:issue`, recreate the app so it sees the new `APP_URL`:

```bash
./dock up --force-recreate crm-octane crm-queue crm-scheduler crm-reverb
```

## 5. Cron

Cron runs in the **server's timezone** (`timedatectl` shows it; most droplets are UTC). Convert local times: 03:00 Asia/Manila = 19:00 UTC → `0 19 * * *`.

```bash
crontab -e
```

```cron
# renew certificates daily
0 19 * * * cd /home/www/laramonde && ./dock tls:renew >> logs/tls-renew.log 2>&1
# per-database Postgres backups daily
0 17 * * * cd /home/www/laramonde && ./dock backup >> logs/backup.log 2>&1
```

Do not install the host `certbot` package as well — the stack's certbot container owns the certificates (Docker volume `multiapp_certbot_certs`).

## 6. Backups and alerts

Set the `BACKUP_*` block in `.env` (Spaces bucket, keys, `BACKUP_REQUIRE_SPACES=1`, optional Discord webhook). Full walkthrough: [Backups and restore](05-backups-and-restore.md). Root `.env` `BACKUP_*` values are read by the script at run time — no container restart needed.

## 7. Day-two operations

```bash
./dock ps                         # health of every container
./dock logs nginx                 # follow one service
./dock resources status           # per-app resource plan
./dock tls:certs                  # certificate expiry
git pull && ./dock up          # update the stack itself
```

When updating the stack with `git pull`, rebuild PHP images if their Dockerfiles changed:

```bash
./dock build crm-octane && ./dock up --force-recreate crm-octane crm-queue crm-scheduler crm-reverb
```

`docker compose down` / `up` is safe, but if nginx then crash-loops on a certificate key, run `./scripts/tls-fix-certs.sh` (see [Troubleshooting](07-troubleshooting.md#nginx-crash-loops)).

## Exposing another service through the shared nginx

To publish a non-Laravel container (an admin UI, a monitoring tool) on its own domain without editing the repo:

1. Run it from its own compose file on a shared external network that nginx also joins (add the network to `nginx/compose.yml` on that server only).
2. Write `nginx/conf.d/sites/<name>.conf` (gitignored) with an HTTP server for `/.well-known/acme-challenge/` + redirect, and an `8443 ssl` server that `proxy_pass`es to the container.
3. Issue the certificate:

   ```bash
   docker compose --profile tls run --rm --entrypoint certbot certbot certonly \
     --webroot -w /var/www/certbot -d tool.example.com \
     --email you@company.com --agree-tos --non-interactive
   ./scripts/tls-fix-certs.sh
   docker compose exec nginx nginx -t && docker compose exec nginx nginx -s reload
   ```

nginx resolves `upstream` hosts at start-up: if that container is removed, nginx will not start until it is back or the `.conf` is deleted.

## Production checklist

- [ ] `NGINX_BIND=0.0.0.0`, `CERTBOT_STAGING=0`, profile `tls` enabled
- [ ] DNS points at the server; `./dock tls:certs` lists every domain
- [ ] Cron for `tls:renew` and `backup`, times converted to server timezone
- [ ] `BACKUP_REQUIRE_SPACES=1` and a test `./dock backup` uploaded successfully
- [ ] Discord/email alert tested
- [ ] Each app: `APP_ENV=production`, `APP_DEBUG=false`, real mail settings (see [mail override](03-apps.md#mail-and-app-name-are-injected))
- [ ] Outbound SMTP tested from an app container
- [ ] Swap configured on small hosts
