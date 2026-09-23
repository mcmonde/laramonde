#!/usr/bin/env bash
# Remove an app from the stack (compose include, nginx, site dir, apps.list).
# Does NOT drop the Postgres database unless --drop-db is passed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/_lib.sh
source "$ROOT/scripts/_lib.sh"

APP=""
DROP_DB=0
REMOVE_CODE=0
FORCE=0

usage() {
  cat <<'EOF'
Usage: remove-app.sh <app-name> [--drop-db] [--remove-code] [--force]

Stops app containers, removes compose include, nginx site, sites/<app>/,
and the postgres/apps.list row. Laravel code and DB are kept by default.

  --drop-db       DROP DATABASE / ROLE in running Postgres (destructive)
  --remove-code   Delete apps/<app>/ on disk
  --force         Skip confirmation prompt
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --drop-db) DROP_DB=1; shift ;;
    --remove-code) REMOVE_CODE=1; shift ;;
    --force|-f) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      if [[ -z "$APP" ]]; then APP="$1"; else echo "Unexpected: $1"; usage; exit 1; fi
      shift
      ;;
  esac
done

if [[ -z "$APP" ]]; then
  usage
  exit 1
fi

case "$APP" in
  _*) echo "Refusing to remove template app: $APP"; exit 1 ;;
esac

require_app "$APP"

SITE_DIR="$ROOT/sites/$APP"
CODE_DIR="$ROOT/apps/$APP"
COMPOSE_FILE="$ROOT/docker-compose.yml"
APPS_LIST="$ROOT/postgres/apps.list"
NGINX_SITE="$ROOT/nginx/conf.d/sites/${APP}.conf"

echo "Will remove app: $APP"
echo "  site dir     : $SITE_DIR"
echo "  nginx        : $NGINX_SITE"
echo "  compose include + apps.list row"
if [[ "$DROP_DB" -eq 1 ]]; then echo "  Postgres DB  : DROP (requested)"; fi
if [[ "$REMOVE_CODE" -eq 1 ]]; then echo "  code dir     : $CODE_DIR (delete)"; fi
echo

if [[ "$FORCE" -ne 1 ]]; then
  if ! prompt_continue "Remove app '${APP}' from the stack?"; then
    echo "Aborted."
    exit 1
  fi
fi

# shellcheck disable=SC1091
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ROOT/.env"
  set +a
fi

services=()
for svc in "${APP}-php" "${APP}-octane" "${APP}-queue" "${APP}-scheduler" "${APP}-reverb"; do
  if "${COMPOSE[@]}" config --services 2>/dev/null | grep -qx "$svc"; then
    services+=("$svc")
  fi
done
if [[ ${#services[@]} -gt 0 ]]; then
  echo "Stopping: ${services[*]}"
  "${COMPOSE[@]}" stop "${services[@]}" 2>/dev/null || true
  "${COMPOSE[@]}" rm -f "${services[@]}" 2>/dev/null || true
fi

if [[ "$DROP_DB" -eq 1 ]]; then
  line="$(grep -E "^${APP}[[:space:]]" "$APPS_LIST" 2>/dev/null || true)"
  if [[ -n "$line" ]]; then
    db="$(echo "$line" | awk '{print $2}')"
    user="$(echo "$line" | awk '{print $3}')"
    if "${COMPOSE[@]}" ps postgres --status running --format '{{.Name}}' 2>/dev/null | grep -q .; then
      echo "Dropping Postgres database/role ${db}/${user}…"
      "${COMPOSE[@]}" exec -T postgres \
        psql -U "${POSTGRES_USER:-postgres}" -v ON_ERROR_STOP=1 \
        -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${db}' AND pid <> pg_backend_pid();" \
        -c "DROP DATABASE IF EXISTS \"${db}\";" \
        -c "DROP ROLE IF EXISTS \"${user}\";" || true
    else
      echo "Postgres is not running — skip --drop-db."
    fi
  fi
fi

if [[ -f "$APPS_LIST" ]]; then
  awk -v app="$APP" '$1!=app { print }' "$APPS_LIST" > "${APPS_LIST}.tmp"
  mv "${APPS_LIST}.tmp" "$APPS_LIST"
  chmod 600 "$APPS_LIST" 2>/dev/null || true
fi

if grep -q "path: sites/${APP}/compose.yml" "$COMPOSE_FILE"; then
  awk -v app="$APP" '
    BEGIN { skip = 0 }
    $0 ~ ("path: sites/" app "/compose.yml") { skip = 1; next }
    skip && /^  - path:/ { skip = 0; print; next }
    skip && /^  #/ { skip = 0; print; next }
    skip { next }
    { print }
  ' "$COMPOSE_FILE" > "${COMPOSE_FILE}.tmp"
  mv "${COMPOSE_FILE}.tmp" "$COMPOSE_FILE"
fi

rm -f "$NGINX_SITE"
rm -rf "$SITE_DIR"

if [[ "$REMOVE_CODE" -eq 1 && -e "$CODE_DIR" ]]; then
  rm -rf "$CODE_DIR"
  echo "Deleted $CODE_DIR"
fi

if [[ -f "$ROOT/.env" ]]; then
  "$ROOT/scripts/resources.sh" apply || true
fi

echo
echo "Removed app: $APP"
echo "  Reload nginx if running: ./dock restart nginx"
if [[ "$DROP_DB" -eq 0 ]]; then
  echo "  Postgres database kept (use --drop-db next time only if the list row still exists)."
fi
