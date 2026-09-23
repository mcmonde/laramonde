#!/usr/bin/env bash
# Make Let's Encrypt certs readable by unprivileged nginx (UID 101).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/_lib.sh
source "$ROOT/scripts/_lib.sh"

# nginxinc/nginx-unprivileged runs as UID 101
NGINX_UID=101

"${COMPOSE[@]}" run --rm --no-deps --entrypoint /bin/sh --user root --profile tls certbot -c "
set -e
if [ ! -d /etc/letsencrypt/live ]; then
  echo 'No certificates yet'
  exit 0
fi
chmod 755 /etc/letsencrypt /etc/letsencrypt/live /etc/letsencrypt/archive 2>/dev/null || true
find /etc/letsencrypt/live -type d -exec chmod 755 {} \;
find /etc/letsencrypt/archive -type d -exec chmod 755 {} \;
find /etc/letsencrypt -name 'fullchain*.pem' -exec chmod 644 {} \;
find /etc/letsencrypt -name 'cert*.pem' -exec chmod 644 {} \;
find /etc/letsencrypt -name 'chain*.pem' -exec chmod 644 {} \;
find /etc/letsencrypt -name 'privkey*.pem' -exec chmod 640 {} \;
find /etc/letsencrypt -name 'privkey*.pem' -exec chown root:${NGINX_UID} {} \;
echo 'Certificate permissions updated for nginx UID ${NGINX_UID}'
"
