# Migrating an existing app

Move a Laravel app from another server (Laradock, bare metal, another multi-app host) without touching the old server: copy code, database and uploads, test on the new server, then switch DNS.

Throughout, `OLD` is the source server and `NEW` the multi-app host.

## 1. Inspect the old app

On `OLD`, note:

```bash
cd /path/to/app
php artisan --version                              # Laravel version (or inside its container)
php -v                                             # PHP version actually running
grep -E '^(DB_CONNECTION|DB_DATABASE|CACHE_DRIVER|QUEUE_CONNECTION|SESSION_DRIVER|MAIL_MAILER|FILESYSTEM)' .env
git status                                         # uncommitted production-only changes?
du -sh storage/app                                 # uploads to copy
crontab -l                                         # is schedule:run actually running?
```

Decide:

- **PHP version:** match what production runs today (`--php 8.3`), not only what the framework documentation says. Check `composer.lock` for packages requiring `php >= 8.2`.
- **Database:** this stack runs Postgres. A MySQL app needs its data converted (e.g. `pgloader`) and MySQL-specific SQL (`DATE_FORMAT`, `GROUP_CONCAT`, …) rewritten — plan that separately.
- **Scheduler/queue:** if the old server never ran `schedule:run`, enabling the scheduler starts jobs that never ran before. Delete `<app>-scheduler` from `sites/<app>/compose.yml` until you decide.
- **Laravel < 11:** follow [Older Laravel versions](03-apps.md#older-laravel-versions-810).

## 2. Create the app on NEW

```bash
./dock new-app myapp myapp.example.com --php 8.3
./dock db:create myapp            # if the DB was not created (Postgres started earlier)
```

Adjust `sites/myapp/compose.yml` as decided above (Reverb, scheduler, mail overrides).

## 3. Copy the code

Stream from OLD to NEW through your workstation (read-only on OLD):

```bash
ssh root@OLD 'cd /path/to/app && tar -czf - \
    --exclude=./storage/logs --exclude=./storage/framework/cache/data \
    --exclude=./storage/framework/sessions --exclude=./storage/framework/views \
    --exclude=./public/storage --exclude=./node_modules .' \
| ssh root@NEW 'cd /home/www/laramonde/apps/myapp && rm -f .gitkeep && tar -xzf - \
    && mkdir -p storage/logs storage/framework/{cache/data,sessions,views} \
    && chown -R 1000:1000 .'
```

This keeps `.env` (and therefore `APP_KEY` — required to decrypt existing encrypted data and cookies), `vendor/`, `storage/app` uploads and any uncommitted production edits.

Restore placeholder files git tracks inside the excluded folders:

```bash
cd apps/myapp && git -c safe.directory='*' checkout -- storage/ && chown -R 1000:1000 storage
```

## 4. Copy the database

The old dump is owned by the old database user. Restore it **without owners or grants** as the new app role, so everything ends up owned by `myapp`:

**Old database is Postgres** (custom format, streamed, nothing written on OLD):

```bash
ssh root@OLD 'docker exec <old-postgres-container> pg_dump -U <old-user> -Fc <old-db>' \
  | ssh root@NEW 'cat > /root/myapp.dump'

ssh root@NEW 'cd /home/www/laramonde && docker compose exec -T postgres \
  pg_restore -U myapp -d myapp --no-owner --no-acl --exit-on-error < /root/myapp.dump'
```

**You only have a plain `.sql.gz`:** strip ownership statements on the fly:

```bash
gunzip -c old.sql.gz \
  | sed -E '/^ALTER .* OWNER TO /d; /^(GRANT|REVOKE) /d' \
  | docker compose exec -T postgres psql -U myapp -d myapp -v ON_ERROR_STOP=1
```

Verify table and row counts match OLD before going further.

## 5. Wire Laravel to the new stack

- Container environment already points `DB_*`, `REDIS_*`, `APP_URL` at the new stack (see [who wins](03-apps.md#environment-files-who-wins)).
- Keep the old `.env` for everything else (mail, third-party keys, `APP_KEY`).

```bash
./dock up
./dock artisan myapp optimize:clear
./dock artisan myapp storage:link
./dock artisan myapp migrate:status
```

Test through nginx before DNS changes:

```bash
curl -H "Host: myapp.example.com" http://NEW_IP/
```

Also test: login, file downloads/uploads, PDF/Excel exports, outgoing mail (from inside the container), queued jobs.

## 6. Cut over

1. Lower the DNS TTL a day ahead if you can.
2. Point the domain's `A` record at NEW.
3. **Re-sync data written on OLD since the test copy:** repeat step 4 into a fresh database (`dropdb`/`./dock db:create`) and `rsync` `storage/app` again.
4. `./dock tls:issue myapp`, then re-apply any vhost customisations (Reverb removal, rate-limit burst).
5. Add cron (`tls:renew`, `backup`) if this is the first app on NEW.

Leave OLD running unchanged until NEW has been stable for a few days.
