#!/usr/bin/env bash
# Per-app PHP extensions / apt packages on top of the shared image.
# The app then builds its own tag (<image>:<php><suffix>) that reuses every shared layer.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/_lib.sh
source "$ROOT/scripts/_lib.sh"

usage() {
  cat <<'EOF'
Usage: extras.sh <app> [--php-ext "ext1 ext2"] [--apt "pkg1 pkg2"] [--clear]

Without options: show the app's current extras.

  --php-ext LIST   PHP extensions (install-php-extensions names, e.g. "imagick soap ldap")
  --apt LIST       Debian packages (e.g. "ghostscript poppler-utils")
  --clear          Remove all extras (app goes back to the shared image)

Apply afterwards:
  ./dock up --build --force-recreate <app>-php <app>-queue <app>-scheduler
  docker compose exec nginx nginx -s reload

Find out what an app needs first: ./dock scan-app <repo-url|path>
EOF
}

APP=""
PHP_EXT=""
APT=""
SET_EXT=0
SET_APT=0
CLEAR=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --php-ext) [[ $# -ge 2 ]] || { echo "--php-ext needs a list"; exit 1; }; PHP_EXT="$2"; SET_EXT=1; shift 2 ;;
    --php-ext=*) PHP_EXT="${1#--php-ext=}"; SET_EXT=1; shift ;;
    --apt) [[ $# -ge 2 ]] || { echo "--apt needs a list"; exit 1; }; APT="$2"; SET_APT=1; shift 2 ;;
    --apt=*) APT="${1#--apt=}"; SET_APT=1; shift ;;
    --clear) CLEAR=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1"; usage; exit 1 ;;
    *)
      if [[ -z "$APP" ]]; then APP="$1"; else echo "Unexpected: $1"; usage; exit 1; fi
      shift
      ;;
  esac
done

[[ -n "$APP" ]] || { usage; exit 1; }
require_app "$APP"

DEFAULTS="$(site_defaults "$APP")"
COMPOSE_FILE="$ROOT/sites/$APP/compose.yml"

normalize() {
  # collapse commas/whitespace into single spaces, drop duplicates, keep order
  echo "$1" | tr ',A-Z' ' a-z' | xargs -n1 2>/dev/null | awk '!seen[$0]++' | xargs 2>/dev/null || true
}

validate_list() {
  local what="$1" list="$2"
  local item
  for item in $list; do
    if [[ ! "$item" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]]; then
      echo "Invalid $what name: '$item'"
      exit 1
    fi
  done
}

# Older sites/<app>/compose.yml files predate per-app extras; add the tag suffix + build args.
upgrade_compose() {
  [[ -f "$COMPOSE_FILE" ]] || return 0
  if grep -q 'APP_IMAGE_SUFFIX' "$COMPOSE_FILE" && grep -q 'APP_PHP_EXTENSIONS' "$COMPOSE_FILE"; then
    return 0
  fi
  cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak-extras"
  awk '
    /^  image: / && $0 !~ /APP_IMAGE_SUFFIX/ {
      print $0 "${APP_IMAGE_SUFFIX:-}"
      next
    }
    /^      APP_GID: / && !args_done {
      print
      print "      APP_PHP_EXTENSIONS: ${APP_PHP_EXTENSIONS:-}"
      print "      APP_APT_PACKAGES: ${APP_APT_PACKAGES:-}"
      args_done = 1
      next
    }
    { print }
  ' "${COMPOSE_FILE}.bak-extras" > "$COMPOSE_FILE"
  echo "Upgraded sites/${APP}/compose.yml for per-app extras (backup: compose.yml.bak-extras)"
}

show() {
  local ext apt suffix
  ext="$(env_get APP_PHP_EXTENSIONS "$DEFAULTS")"
  apt="$(env_get APP_APT_PACKAGES "$DEFAULTS")"
  suffix="$(env_get APP_IMAGE_SUFFIX "$DEFAULTS")"
  echo "App: $APP"
  echo "  PHP extensions : ${ext:-<none>}"
  echo "  apt packages   : ${apt:-<none>}"
  if [[ -n "$suffix" ]]; then
    echo "  image          : own tag (…:<php>${suffix}), built on the shared image layers"
  else
    echo "  image          : shared"
  fi
}

if [[ "$CLEAR" -eq 0 && "$SET_EXT" -eq 0 && "$SET_APT" -eq 0 ]]; then
  show
  exit 0
fi

if [[ "$CLEAR" -eq 1 ]]; then
  PHP_EXT=""; APT=""; SET_EXT=1; SET_APT=1
fi

[[ "$SET_EXT" -eq 1 ]] || PHP_EXT="$(env_get APP_PHP_EXTENSIONS "$DEFAULTS")"
[[ "$SET_APT" -eq 1 ]] || APT="$(env_get APP_APT_PACKAGES "$DEFAULTS")"
PHP_EXT="$(normalize "$PHP_EXT")"
APT="$(normalize "$APT")"
validate_list "PHP extension" "$PHP_EXT"
validate_list "apt package" "$APT"

SUFFIX=""
if [[ -n "$PHP_EXT" || -n "$APT" ]]; then
  SUFFIX="-${APP}"
fi

upgrade_compose
env_set APP_PHP_EXTENSIONS "$PHP_EXT" "$DEFAULTS"
env_set APP_APT_PACKAGES "$APT" "$DEFAULTS"
env_set APP_IMAGE_SUFFIX "$SUFFIX" "$DEFAULTS"
chmod 600 "$DEFAULTS" 2>/dev/null || true

show
runtime="$(app_runtime "$APP")"
if [[ "$runtime" == "octane" ]]; then http="${APP}-octane"; else http="${APP}-php"; fi
echo
echo "Apply:"
echo "  ./dock up --build --force-recreate ${http} ${APP}-queue ${APP}-scheduler"
echo "  docker compose exec nginx nginx -s reload"
