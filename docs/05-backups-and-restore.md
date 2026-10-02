# Backups and restore

`./dock backup` dumps **each app database separately** (plus Postgres globals), verifies the gzip, and on staging/production uploads every file privately to DigitalOcean Spaces (any S3-compatible storage works).

## What gets backed up

- Every database listed in `sites/*/defaults.env` (`DB_DATABASE`) and `postgres/apps.list`.
- `globals_<timestamp>.sql.gz` — roles and their attributes (`pg_dumpall --globals-only`), only when backing up all databases.
- **Not** included: `apps/<app>/storage` uploads, Redis, Meilisearch indexes (rebuildable with `scout:import`), certificates.

Files: `backups/postgres/<db>_<YYYYmmdd_HHMMSS>.sql.gz`, plain SQL, gzip, mode `600`.

```bash
./dock backup            # all app databases + globals
./dock backup crm        # one database
```

## Local / development

Leave the `BACKUP_S3_*` variables unset and `BACKUP_REQUIRE_SPACES=0` (default). Dumps stay in `backups/postgres/`, the command exits 0, and it prints a reminder that nothing was uploaded.

## Staging / production with Spaces

1. In DigitalOcean create a **Space** (private) and a **Spaces access key**.
2. In the root `.env`:

   ```env
   BACKUP_REQUIRE_SPACES=1
   BACKUP_S3_ENDPOINT=https://sgp1.digitaloceanspaces.com
   BACKUP_S3_REGION=sgp1
   BACKUP_S3_BUCKET=your-space
   BACKUP_S3_PREFIX=database-backups/<server-ip>     # filled by ./dock setup
   BACKUP_S3_ACCESS_KEY_ID=...
   BACKUP_S3_SECRET_ACCESS_KEY=...
   BACKUP_S3_RETAIN_DAYS=30
   ```

3. Run `./dock backup` once by hand and check the objects in the Space.
4. Add the cron line from [Production → Cron](02-production.md#5-cron).

No container restart is needed — the script reads `.env` each run.

### Fail-safes

- Uploads use `--acl private`, go to a temporary key first, are renamed, re-marked private, and their size is compared with the local file.
- **Local files are deleted only after a verified upload.** If an upload fails the file stays in `backups/postgres/` and is retried on the next run.
- Objects older than `BACKUP_S3_RETAIN_DAYS` (and leftover `.tmp.` keys) are pruned from the bucket.
- A lock file prevents overlapping runs.
- Missing Spaces config with `BACKUP_REQUIRE_SPACES=1` is an error (exit 1 + alert).

## Failure alerts (Discord or email)

**Discord** (free): in your Discord server, open the channel → *Edit Channel* → *Integrations* → *Webhooks* → *New Webhook* → *Copy Webhook URL*. Then:

```env
BACKUP_ALERT_WEBHOOK=https://discord.com/api/webhooks/<id>/<token>
```

Discord is detected from the URL (or force with `BACKUP_ALERT_PROVIDER=discord`). Treat the URL as a secret — anyone with it can post to the channel.

**Email:** `BACKUP_ALERT_EMAIL=ops@company.com` (needs a working `mail`/`sendmail` on the host).

Alerts are sent when a dump fails, an upload fails, a database is missing, or Spaces is required but not configured.

## Restore

### From a local file

```bash
cd /home/www/laramonde
# 1. Stop writers to this database
docker compose stop crm-octane crm-queue crm-scheduler

# 2. Recreate an empty database owned by the app role
docker compose exec postgres dropdb -U postgres --if-exists crm
./dock db:create crm

# 3. Load the dump
gunzip -c backups/postgres/crm_20260101_010000.sql.gz \
  | docker compose exec -T postgres psql -U postgres -d crm -v ON_ERROR_STOP=1

# 4. Start the app again
./dock up crm-octane crm-queue crm-scheduler
```

Dumps are made with the stack's own roles, so ownership matches as long as the app keeps the same name. Restoring into a **different** app/database name: strip owners as in [Migrating → database](04-migrating-an-app.md#4-copy-the-database).

### From Spaces

Download with any S3 client, for example the AWS CLI image:

```bash
docker run --rm -v "$PWD/backups/postgres:/out" \
  -e AWS_ACCESS_KEY_ID=... -e AWS_SECRET_ACCESS_KEY=... \
  amazon/aws-cli --endpoint-url https://sgp1.digitaloceanspaces.com \
  s3 cp s3://your-space/database-backups/<server-ip>/crm_20260101_010000.sql.gz /out/
```

Then restore as above.

### Roles on a brand-new server

Restoring onto a fresh stack: create the apps first (`./dock new-app`), which creates matching roles with new passwords. Only load `globals_*.sql.gz` if you need roles that the stack does not create; it also contains password hashes from the old server.

## Test your restores

A backup you have never restored is a guess. Periodically restore the latest dump into a scratch database:

```bash
docker compose exec postgres createdb -U postgres restore_test
gunzip -c backups/postgres/crm_*.sql.gz | docker compose exec -T postgres psql -U postgres -d restore_test -q
docker compose exec postgres dropdb -U postgres restore_test
```
