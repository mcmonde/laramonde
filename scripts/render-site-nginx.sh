#!/usr/bin/env bash
# Render nginx/conf.d/sites/<app>.conf from templates based on
# APP_LAYOUT + APP_RUNTIME + APP_TLS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/_lib.sh
source "$ROOT/scripts/_lib.sh"

APP="${1:-}"
if [[ -z "$APP" ]]; then
  echo "Usage: $0 <app-name>"
  exit 1
fi

require_app "$APP"

SITE_DIR="$ROOT/sites/$APP"
DEFAULTS="$(site_defaults "$APP")"
DOMAIN="$(app_domain "$APP")"
RUNTIME="$(app_runtime "$APP")"
TLS="$(app_tls "$APP")"
LAYOUT="$(app_layout "$APP")"
DBIDENT="$(env_get DB_DATABASE "$DEFAULTS")"
DBIDENT="${DBIDENT:-${APP//-/_}}"
OUT="$ROOT/nginx/conf.d/sites/${APP}.conf"

if [[ -z "$DOMAIN" ]]; then
  echo "APP_DOMAIN is empty in $DEFAULTS"
  exit 1
fi

case "$LAYOUT" in
  spa|standard) ;;
  *)
    echo "Unknown APP_LAYOUT='$LAYOUT' (use spa or standard)"
    exit 1
    ;;
esac

if [[ "$LAYOUT" == "spa" && "$TLS" == "1" && "$RUNTIME" == "octane" ]]; then
  TEMPLATE="$ROOT/nginx/templates/site-spa-octane-ssl.conf.template"
elif [[ "$LAYOUT" == "spa" && "$TLS" == "1" ]]; then
  TEMPLATE="$ROOT/nginx/templates/site-spa-ssl.conf.template"
elif [[ "$LAYOUT" == "spa" && "$RUNTIME" == "octane" ]]; then
  TEMPLATE="$ROOT/nginx/templates/site-spa-octane.conf.template"
elif [[ "$LAYOUT" == "spa" ]]; then
  TEMPLATE="$ROOT/nginx/templates/site-spa.conf.template"
elif [[ "$TLS" == "1" && "$RUNTIME" == "octane" ]]; then
  TEMPLATE="$ROOT/nginx/templates/site-octane-ssl.conf.template"
elif [[ "$TLS" == "1" ]]; then
  TEMPLATE="$ROOT/nginx/templates/site-ssl.conf.template"
elif [[ "$RUNTIME" == "octane" ]]; then
  TEMPLATE="$ROOT/nginx/templates/site-octane.conf.template"
else
  TEMPLATE="$ROOT/nginx/templates/site.conf.template"
fi

DB_PASSWORD="$(env_get DB_PASSWORD "$DEFAULTS")"
REVERB_KEY="$(env_get REVERB_APP_KEY "$DEFAULTS")"
REVERB_SECRET="$(env_get REVERB_APP_SECRET "$DEFAULTS")"

# shellcheck disable=SC1091
set -a
# shellcheck source=/dev/null
source "$ROOT/.env"
set +a
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
MEILI_MASTER_KEY="${MEILI_MASTER_KEY:-}"
SCOUT_DRIVER="${SCOUT_DRIVER:-null}"
MEILISEARCH_HOST="${MEILISEARCH_HOST:-}"
MAIL_MAILER="${MAIL_MAILER:-log}"
MAIL_HOST="${MAIL_HOST:-}"
MAIL_PORT="${MAIL_PORT:-2525}"

SCHEME="http"
REVERB_PORT="80"
if [[ "$TLS" == "1" ]]; then
  SCHEME="https"
  REVERB_PORT="443"
fi

if [[ "$LAYOUT" == "spa" ]]; then
  APP_URL_VALUE="${SCHEME}://${DOMAIN}/api"
  FRONTEND_URL_VALUE="${SCHEME}://${DOMAIN}"
else
  APP_URL_VALUE="${SCHEME}://${DOMAIN}"
  FRONTEND_URL_VALUE="${SCHEME}://${DOMAIN}"
fi

cp "$TEMPLATE" "$OUT"
sed -i \
  -e "s/__APP__/${APP}/g" \
  -e "s/__DBIDENT__/${DBIDENT}/g" \
  -e "s/__DOMAIN__/${DOMAIN}/g" \
  "$OUT"

LARAVEL_SNIPPET="$SITE_DIR/.env.laravel.example"
if [[ "$RUNTIME" == "octane" ]]; then
  SRC="$ROOT/sites/_template_octane/.env.laravel.example"
else
  SRC="$ROOT/sites/_template/.env.laravel.example"
fi
cp "$SRC" "$LARAVEL_SNIPPET"
esc() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'; }
sed -i \
  -e "s/__APP__/${APP}/g" \
  -e "s/__DBIDENT__/${DBIDENT}/g" \
  -e "s/__DOMAIN__/${DOMAIN}/g" \
  -e "s|http://__DOMAIN__|${SCHEME}://${DOMAIN}|g" \
  -e "s|APP_URL=http://|APP_URL=${SCHEME}://|g" \
  -e "s/__DB_PASSWORD__/$(esc "$DB_PASSWORD")/g" \
  -e "s/__REDIS_PASSWORD__/$(esc "$REDIS_PASSWORD")/g" \
  -e "s/__MEILI_MASTER_KEY__/$(esc "$MEILI_MASTER_KEY")/g" \
  -e "s/__SCOUT_DRIVER__/$(esc "$SCOUT_DRIVER")/g" \
  -e "s|__MEILISEARCH_HOST__|$(esc "$MEILISEARCH_HOST")|g" \
  -e "s/__MAIL_MAILER__/$(esc "$MAIL_MAILER")/g" \
  -e "s|__MAIL_HOST__|$(esc "$MAIL_HOST")|g" \
  -e "s/__MAIL_PORT__/$(esc "$MAIL_PORT")/g" \
  -e "s/__REVERB_APP_KEY__/$(esc "$REVERB_KEY")/g" \
  -e "s/__REVERB_APP_SECRET__/$(esc "$REVERB_SECRET")/g" \
  "$LARAVEL_SNIPPET"

awk -v url="$APP_URL_VALUE" \
    -v frontend="$FRONTEND_URL_VALUE" \
    -v scheme="$SCHEME" \
    -v port="$REVERB_PORT" \
    -v host="$DOMAIN" \
    -v layout="$LAYOUT" '
  index($0, "APP_URL=") == 1 { print "APP_URL=" url; next }
  index($0, "ASSET_URL=") == 1 { print "ASSET_URL=" url; next }
  index($0, "FRONTEND_URL=") == 1 { print "FRONTEND_URL=" frontend; next }
  index($0, "SANCTUM_STATEFUL_DOMAINS=") == 1 { print "SANCTUM_STATEFUL_DOMAINS=" host; next }
  index($0, "SESSION_DOMAIN=") == 1 {
    if (layout == "spa") print "SESSION_DOMAIN=" host
    else print "SESSION_DOMAIN=null"
    next
  }
  index($0, "REVERB_HOST=") == 1 { print "REVERB_HOST=" host; next }
  index($0, "REVERB_PORT=") == 1 { print "REVERB_PORT=" port; next }
  index($0, "REVERB_SCHEME=") == 1 { print "REVERB_SCHEME=" scheme; next }
  { print }
' "$LARAVEL_SNIPPET" > "${LARAVEL_SNIPPET}.tmp"
mv "${LARAVEL_SNIPPET}.tmp" "$LARAVEL_SNIPPET"

# Ensure spa-related keys exist even if template lacked them
if [[ "$LAYOUT" == "spa" ]]; then
  if ! grep -qE '^ASSET_URL=' "$LARAVEL_SNIPPET"; then
    printf 'ASSET_URL=%s\n' "$APP_URL_VALUE" >> "$LARAVEL_SNIPPET"
  fi
  if ! grep -qE '^FRONTEND_URL=' "$LARAVEL_SNIPPET"; then
    printf 'FRONTEND_URL=%s\n' "$FRONTEND_URL_VALUE" >> "$LARAVEL_SNIPPET"
  fi
  if ! grep -qE '^SANCTUM_STATEFUL_DOMAINS=' "$LARAVEL_SNIPPET"; then
    printf 'SANCTUM_STATEFUL_DOMAINS=%s\n' "$DOMAIN" >> "$LARAVEL_SNIPPET"
  fi
  if ! grep -qE '^SESSION_DOMAIN=' "$LARAVEL_SNIPPET"; then
    printf 'SESSION_DOMAIN=%s\n' "$DOMAIN" >> "$LARAVEL_SNIPPET"
  fi
fi

env_set APP_URL "$APP_URL_VALUE" "$DEFAULTS"
env_set APP_LAYOUT "$LAYOUT" "$DEFAULTS"
chmod 600 "$DEFAULTS" 2>/dev/null || true

echo "Rendered $OUT (layout=${LAYOUT}, runtime=${RUNTIME}, tls=${TLS}, domain=${DOMAIN})"
if [[ "$LAYOUT" == "spa" ]]; then
  echo "  /              → apps/${APP}/frontend/dist (SPA)"
  echo "  /api/          → Laravel"
  echo "  /app           → Reverb"
  echo "  /sanctum/      → Laravel (cookie auth)"
  echo "  /broadcasting/ → Laravel (Echo auth)"
  echo "  /up            → Laravel health"
fi
