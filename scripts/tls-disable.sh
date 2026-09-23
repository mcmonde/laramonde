#!/usr/bin/env bash
# Disable HTTPS for an app — re-render HTTP-only nginx site (certs kept on disk).
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
DOMAIN="$(app_domain "$APP")"
DEFAULTS="$(site_defaults "$APP")"

env_set APP_TLS 0 "$DEFAULTS"
env_set APP_URL "http://${DOMAIN}" "$DEFAULTS"
chmod 600 "$DEFAULTS"

"$ROOT/scripts/render-site-nginx.sh" "$APP"
nginx_reload

echo "TLS disabled for ${APP}. Serving http://${DOMAIN} (certificates left in place)."
