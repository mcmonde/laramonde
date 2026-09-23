#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/_lib.sh
source "$ROOT/scripts/_lib.sh"

RUNTIME="fpm"
LAYOUT="standard"
APP=""
DOMAIN=""
FORCE=0
SKIP_SCALE=0

usage() {
  cat <<'EOF'
Usage: new-app.sh <app-name> [domain] [--octane] [--spa] [--force] [--skip-scale]

Before creating an app, detects host CPU/RAM and checks whether another app
fits. On success, rescales infra + all apps' container limits.

  --octane       Scaffold Octane/Swoole instead of PHP-FPM
  --spa          Path layout: / → frontend/dist, /api → Laravel, /app → Reverb
  --force        Create even if the resource check fails (not recommended)
  --skip-scale   Skip auto resource check/rescale

Examples:
  ./dock new-app portal
  ./dock new-app portal portal.local --spa
  ./dock new-app api api.example.com --octane --spa
  ./dock new-app billing bill.example.com --force
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --octane|-o) RUNTIME="octane"; shift ;;
    --fpm) RUNTIME="fpm"; shift ;;
    --spa) LAYOUT="spa"; shift ;;
    --force|-f) FORCE=1; shift ;;
    --skip-scale) SKIP_SCALE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      if [[ -z "$APP" ]]; then APP="$1"
      elif [[ -z "$DOMAIN" ]]; then DOMAIN="$1"
      else echo "Unexpected argument: $1"; usage; exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$APP" ]]; then
  usage
  exit 1
fi

if [[ ! "$APP" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "App name must be lowercase alphanumeric, optional hyphens, starting with a letter."
  exit 1
fi

DBIDENT="${APP//-/_}"
DOMAIN="${DOMAIN:-${APP}.local}"
SITE_DIR="$ROOT/sites/$APP"
CODE_DIR="$ROOT/apps/$APP"
COMPOSE="$ROOT/docker-compose.yml"
APPS_LIST="$ROOT/postgres/apps.list"
MARKER="# --- apps (managed by ./dock new-app) ---"

if [[ "$RUNTIME" == "octane" ]]; then
  TEMPLATE_DIR="$ROOT/sites/_template_octane"
  ENV_DEFAULTS_FILE="php-octane/defaults.env"
  HTTP_SERVICE="${APP}-octane"
else
  TEMPLATE_DIR="$ROOT/sites/_template"
  ENV_DEFAULTS_FILE="php-fpm/defaults.env"
  HTTP_SERVICE="${APP}-php"
fi

if [[ -d "$SITE_DIR" ]]; then
  echo "Already exists: $SITE_DIR"
  exit 1
fi

if [[ ! -f "$ROOT/.env" ]]; then
  echo "Run ./dock setup first."
  exit 1
fi

# ---- resource preflight: detect host → capacity → warn/block → continue ----
if [[ "$SKIP_SCALE" -eq 0 ]]; then
  echo "Detecting server CPU/RAM and assessing capacity…"
  echo
  check_args=(1)
  if [[ "$RUNTIME" == "octane" ]]; then
    check_args+=(--octane)
  fi
  set +e
  "$ROOT/scripts/resources.sh" check "${check_args[@]}"
  rc=$?
  set -e
  echo
  case "$rc" in
    0)
      echo "Resource check OK — continuing with calculated allocations."
      ;;
    2)
      echo "Host is near its resource limits for another ${RUNTIME} app."
      if [[ "$FORCE" -eq 1 ]]; then
        echo "WARNING: --force set; continuing past the soft limit."
      else
        if ! prompt_continue "Continue building this app anyway?"; then
          echo "Aborted. Free capacity or use a larger host."
          exit 1
        fi
      fi
      ;;
    *)
      echo "HARD LIMIT: this server cannot fit another ${RUNTIME} app with safe minimums."
      if [[ "$FORCE" -eq 1 ]]; then
        echo "WARNING: --force set; creating anyway. Expect OOM / CPU starvation."
      else
        echo
        echo "Aborted. Options:"
        echo "  ./dock resources assess"
        echo "  Disable heavy profiles in .env (COMPOSE_PROFILES=)"
        echo "  ./dock new-app ${APP} --force   # unsafe override"
        exit 1
      fi
      ;;
  esac
  echo
fi

# shellcheck disable=SC1091
set -a
# shellcheck source=/dev/null
source "$ROOT/.env"
set +a

DB_PASSWORD="$(rand_hex 32)"
REVERB_KEY="$(rand_hex 16)"
REVERB_SECRET="$(rand_hex 32)"

mkdir -p "$SITE_DIR" "$CODE_DIR" "$ROOT/nginx/conf.d/sites"

cp "$TEMPLATE_DIR/compose.yml" "$SITE_DIR/compose.yml"
cp "$TEMPLATE_DIR/defaults.env" "$SITE_DIR/defaults.env"

sed -i \
  -e "s/__APP__/${APP}/g" \
  -e "s/__DBIDENT__/${DBIDENT}/g" \
  -e "s/__DOMAIN__/${DOMAIN}/g" \
  "$SITE_DIR/compose.yml" \
  "$SITE_DIR/defaults.env"

env_set DB_PASSWORD "$DB_PASSWORD" "$SITE_DIR/defaults.env"
env_set REVERB_APP_KEY "$REVERB_KEY" "$SITE_DIR/defaults.env"
env_set REVERB_APP_SECRET "$REVERB_SECRET" "$SITE_DIR/defaults.env"
env_set APP_TLS 0 "$SITE_DIR/defaults.env"
env_set APP_RUNTIME "$RUNTIME" "$SITE_DIR/defaults.env"
env_set APP_LAYOUT "$LAYOUT" "$SITE_DIR/defaults.env"
env_set APP_DOMAIN "$DOMAIN" "$SITE_DIR/defaults.env"
if [[ "$LAYOUT" == "spa" ]]; then
  env_set APP_URL "http://${DOMAIN}/api" "$SITE_DIR/defaults.env"
else
  env_set APP_URL "http://${DOMAIN}" "$SITE_DIR/defaults.env"
fi
chmod 600 "$SITE_DIR/defaults.env"

"$ROOT/scripts/render-site-nginx.sh" "$APP"

if ! grep -q "path: sites/${APP}/compose.yml" "$COMPOSE"; then
  if ! grep -q "$MARKER" "$COMPOSE"; then
    echo "Missing marker in docker-compose.yml: $MARKER"
    exit 1
  fi
  tmp="$(mktemp)"
  awk -v app="$APP" -v marker="$MARKER" -v defaults="$ENV_DEFAULTS_FILE" '
    { print }
    index($0, marker) {
      print "  - path: sites/" app "/compose.yml"
      print "    project_directory: ."
      print "    env_file:"
      print "      - " defaults
      print "      - sites/" app "/defaults.env"
    }
  ' "$COMPOSE" > "$tmp"
  mv "$tmp" "$COMPOSE"
fi

if ! grep -qE "^${APP}[[:space:]]" "$APPS_LIST" 2>/dev/null; then
  printf '%s %s %s %s\n' "$APP" "$DBIDENT" "$DBIDENT" "$DB_PASSWORD" >> "$APPS_LIST"
  chmod 600 "$APPS_LIST"
fi

if docker compose -f "$COMPOSE" --project-directory "$ROOT" ps postgres --status running --format '{{.Name}}' 2>/dev/null | grep -q .; then
  echo "Postgres is running — creating database now..."
  "$ROOT/scripts/create-app-db.sh" "$DBIDENT" "$DBIDENT" "$DB_PASSWORD" || true
fi

# ---- rescale all apps now that the new one exists --------------------------
if [[ "$SKIP_SCALE" -eq 0 ]]; then
  echo
  echo "Rescaling stack for $(find "$ROOT"/sites -mindepth 1 -maxdepth 1 -type d ! -name '_*' | wc -l) app(s)..."
  if ! "$ROOT/scripts/resources.sh" apply; then
    echo "WARNING: app was created but auto-scale failed. Run: ./dock resources apply"
  fi
fi

cat > "$CODE_DIR/.gitkeep" <<EOF
# Place the Laravel project here (runtime=${RUNTIME}, layout=${LAYOUT}).
# HTTPS later: ./dock tls:issue ${APP}
EOF

echo
echo "Created app: $APP (runtime=${RUNTIME}, layout=${LAYOUT})"
echo "  site config : $SITE_DIR"
echo "  nginx       : nginx/conf.d/sites/${APP}.conf"
echo "  code dir    : $CODE_DIR"
if [[ "$LAYOUT" == "spa" ]]; then
  echo "  spa repo    : $CODE_DIR/frontend   (create after Laravel is cloned)"
  echo "  spa dist    : $CODE_DIR/frontend/dist"
fi
echo "  http svc    : $HTTP_SERVICE"
echo "  postgres    : db/user $DBIDENT"
echo "  domain      : $DOMAIN"
echo
echo "Next:"
if [[ "$LAYOUT" == "spa" ]]; then
  echo "  1. Clone Laravel into an empty dir, then move in (apps/${APP} is not empty — has .gitkeep):"
  echo "       git clone <api-repo-url> /tmp/${APP}-api"
  echo "       rsync -a --delete --exclude frontend/ /tmp/${APP}-api/ $CODE_DIR/"
  echo "       rm -rf /tmp/${APP}-api"
  echo "  2. Clone SPA and build:"
  echo "       git clone <spa-repo-url> $CODE_DIR/frontend"
  echo "       cd $CODE_DIR/frontend && npm ci && npm run build"
  step=3
else
  echo "  1. Clone Laravel (dir has .gitkeep — use rsync or remove it first):"
  echo "       git clone <repo-url> /tmp/${APP}-src && rsync -a /tmp/${APP}-src/ $CODE_DIR/ && rm -rf /tmp/${APP}-src"
  step=2
fi
if [[ "$RUNTIME" == "octane" ]]; then
  echo "  ${step}. composer require laravel/octane && php artisan octane:install --server=swoole"
  step=$((step + 1))
fi
echo "  ${step}. Merge sites/${APP}/.env.laravel.example into the app .env"
step=$((step + 1))
if [[ "$LAYOUT" == "spa" ]]; then
  echo "       (APP_URL ends with /api; FRONTEND_URL is the site root)"
fi
echo "  ${step}. Add hosts entry if local:  127.0.0.1 ${DOMAIN}"
step=$((step + 1))
echo "  ${step}. ./dock up --force-recreate"
step=$((step + 1))
echo "  ${step}. ./dock artisan ${APP} key:generate && ./dock artisan ${APP} migrate"
echo
if [[ "$LAYOUT" == "spa" ]]; then
  echo "URLs: http://${DOMAIN}/  (SPA)  ·  http://${DOMAIN}/api/  (Laravel)  ·  /app (Reverb)"
  echo "Also routed to Laravel: /sanctum/*  /broadcasting/*  /up"
fi
echo "Resources: ./dock resources status"
echo "HTTPS:     ./dock tls:issue ${APP}"
echo
echo "If Postgres was already initialized before this app existed:"
echo "  ./dock db:create ${APP}"
