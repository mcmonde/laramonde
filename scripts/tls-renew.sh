#!/usr/bin/env bash
# Renew all Let's Encrypt certs, fix permissions, reload nginx.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/_lib.sh
source "$ROOT/scripts/_lib.sh"

# shellcheck disable=SC1091
set -a
# shellcheck source=/dev/null
source "$ROOT/.env"
set +a

STAGING_ARGS=()
if [[ "${CERTBOT_STAGING:-0}" == "1" ]]; then
  STAGING_ARGS=(--staging)
fi

echo "Renewing certificates..."
"${COMPOSE[@]}" run --rm --entrypoint certbot --profile tls certbot renew \
  --webroot -w /var/www/certbot \
  "${STAGING_ARGS[@]}" \
  --non-interactive

"$ROOT/scripts/tls-fix-certs.sh"
nginx_reload

echo "Renew complete."
