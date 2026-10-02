# multi-app documentation

Guides for running several Laravel apps on one host with this stack. Start with the guide that matches what you are doing.

| Guide | Read this when you want to… |
|-------|-----------------------------|
| [Getting started (local)](01-getting-started.md) | Run the stack on your machine and add your first app |
| [Production server](02-production.md) | Put the stack on a fresh server with HTTPS, cron, backups and alerts |
| [Managing apps](03-apps.md) | Add/remove apps, pick PHP versions, Octane/SPA, older Laravel, deploy updates, understand env files |
| [Migrating an existing app](04-migrating-an-app.md) | Move a Laravel app (code + database + uploads) from another server |
| [Backups and restore](05-backups-and-restore.md) | Configure Postgres backups to Spaces and restore them |
| [Meilisearch](06-meilisearch.md) | Use Laravel Scout + Meilisearch per app, per-app keys, admin UI |
| [Troubleshooting](07-troubleshooting.md) | Something is broken — symptoms, causes, fixes |

The top-level [README](../README.md) is the quick reference (commands, profiles, images).

## Mental model in 30 seconds

```text
                ┌──────────── shared ────────────┐
 internet ──▶  nginx  ──▶  postgres  redis  meilisearch (optional)
                │
                ├─▶ <app>-php / <app>-octane   (one per app)
                │     <app>-queue   <app>-scheduler   <app>-reverb
                └─▶ …next app
```

- **Shared:** one nginx, one Postgres, one Redis, optional Meilisearch/Mailpit.
- **Per app:** its own PHP container(s), its own database + role, its own Redis/Scout prefix, its own nginx vhost.
- **Files:** stack settings in `.env`, per-app settings in `sites/<app>/`, app code in `apps/<app>/`.
- **CLI:** `./dock` wraps `docker compose` plus the helper scripts in `scripts/`. Run `./dock help` for every command.
