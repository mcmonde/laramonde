# Meilisearch

One shared Meilisearch instance serves every app. Apps are kept apart by index name: `SCOUT_PREFIX=<app>_`, so app `crm`'s `Message` model uses index `crm_messages`.

## Turn it on

In the root `.env`:

```env
COMPOSE_PROFILES=tls,search      # locally: dev,search
MEILI_ENV=production             # staging/production
```

```bash
./dock setup                     # sets SCOUT_DRIVER=meilisearch, MEILISEARCH_HOST=http://meilisearch:7700
./dock up --force-recreate    # env changes need recreate, not restart
```

Without the `search` profile, setup writes `SCOUT_DRIVER=null` and that value is **injected into every app container**, overriding `SCOUT_DRIVER` in the app's own `.env`. If search "does nothing", check the profile first.

Every app container receives:

| Variable | Value |
|----------|-------|
| `SCOUT_DRIVER` | `meilisearch` (or `null`) |
| `MEILISEARCH_HOST` | `http://meilisearch:7700` |
| `MEILISEARCH_KEY` | per-app key from `./dock new-app` (empty if `search` is off) |
| `SCOUT_PREFIX` | `<app>_` |

## Add Scout to an app

```bash
./dock composer crm require laravel/scout meilisearch/meilisearch-php http-interop/http-factory-guzzle
./dock artisan crm vendor:publish --provider="Laravel\Scout\ScoutServiceProvider"
```

Laravel 8 apps: `laravel/scout:^9.8`.

Make a model searchable:

```php
use Laravel\Scout\Searchable;

class Message extends Model
{
    use Searchable;

    public function toSearchableArray(): array
    {
        return [
            'subject' => $this->subject,
            'body' => $this->body,
            'office_id' => $this->office_id,
            'created_at' => $this->created_at?->getTimestamp(),
        ];
    }
}
```

Filterable/sortable attributes go in `config/scout.php` (Scout 10+):

```php
'meilisearch' => [
    'host' => env('MEILISEARCH_HOST'),
    'key' => env('MEILISEARCH_KEY'),
    'index-settings' => [
        App\Models\Message::class => [
            'filterableAttributes' => ['office_id', 'created_at'],
            'sortableAttributes' => ['created_at'],
        ],
    ],
],
```

Push settings and load existing rows:

```bash
./dock artisan crm scout:sync-index-settings
./dock artisan crm scout:import "App\Models\Message"
```

From then on Scout updates the index when models are saved. To index through the queue, set `SCOUT_QUEUE=true` in the app `.env` (the app's `<app>-queue` worker processes it).

Commit `composer.lock`: if `meilisearch/meilisearch-php` is only in `composer.json`, servers without the package fail with *"Please install the suggested Meilisearch client"*.

## Per-app API keys

`./dock new-app` creates a key limited to indexes `<app>_*` and stores it as `APP_MEILI_KEY` in `sites/<app>/defaults.env`. Compose injects that value as `MEILISEARCH_KEY`. App containers do not receive `MEILI_MASTER_KEY`.

The master key stays on the Meilisearch service (and the dev workspace shell). List or revoke keys with `GET /keys` and `DELETE /keys/<uid>` inside that container, using its own `MEILI_MASTER_KEY`. The response includes key secrets, so don't log it.

## Admin UI

Meilisearch's built-in search preview only works with `MEILI_ENV=development`. In production use a separate admin UI such as [Meilisearch-UI](https://github.com/eyeix/meilisearch-ui) (use the small `-lite` image; the full image builds itself at start-up and needs far more memory).

Meilisearch-UI runs in the browser and calls the Meilisearch API directly, so publish both on one HTTPS domain through the shared nginx (pattern in [Production → Exposing another service](02-production.md#exposing-another-service-through-the-shared-nginx)):

- `/` → the UI container, protected with nginx `auth_basic`,
- `/meili/` → `proxy_pass http://meilisearch:7700/;` with **no** `auth_basic` — Meilisearch uses the `Authorization` header for its own key, so basic auth on this path would break it. The API stays protected by Meilisearch keys.

Create a dedicated admin key for the UI (`"actions":["*"],"indexes":["*"]`) instead of sharing the master key, and enter `https://<domain>/meili` as the host in the UI.

## Operations

- **Memory:** defaults allow 2 CPUs / 8 GB. On small hosts set `MEILI_MEMORY=1G` in `.env` (with `RESOURCE_MODE=auto`).
- **Backups:** indexes are rebuildable from Postgres with `scout:import`; backing up the `meilisearch_data` volume is optional.
- **Upgrades:** when changing `MEILI_IMAGE` across versions that change the data format, re-import instead of reusing the volume.
- **Health:** `docker compose exec meilisearch wget -qO- http://127.0.0.1:7700/health`
