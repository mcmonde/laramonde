#!/usr/bin/env bash
# Make Let's Encrypt certs readable by unprivileged nginx (UID 101).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/_lib.sh
source "$ROOT/scripts/_lib.sh"

# nginxinc/nginx-unprivileged runs as UID 101
NGINX_UID=101

"${COMPOSE[@]}" --profile tls run --rm --no-deps --entrypoint /bin/sh --user root certbot -c "
set -e
if [ ! -d /etc/letsencrypt/live ]; then
  echo 'No certificates yet'
  exit 0
fi
# Dirs must be traversable by nginx (chown often fails on this volume driver).
chmod 755 /etc/letsencrypt /etc/letsencrypt/live /etc/letsencrypt/archive 2>/dev/null || true
find /etc/letsencrypt/live /etc/letsencrypt/archive -type d -exec chmod 755 {} \;
find /etc/letsencrypt -name 'fullchain*.pem' -exec chmod 644 {} \;
find /etc/letsencrypt -name 'cert*.pem' -exec chmod 644 {} \;
find /etc/letsencrypt -name 'chain*.pem' -exec chmod 644 {} \;
# Prefer root:${NGINX_UID} + 640 when the volume allows chown.
find /etc/letsencrypt -name 'privkey*.pem' -exec chown root:${NGINX_UID} {} \; 2>/dev/null || true
find /etc/letsencrypt -name 'privkey*.pem' -exec chmod 640 {} \; 2>/dev/null || true
# Always ensure world-readable fallback — otherwise nginx crash-loops and takes
# every TLS site on this host down (seen with crmsbeta privkey after issue).
find /etc/letsencrypt -name 'privkey*.pem' -exec chmod a+r {} \;
echo 'Certificate permissions updated for nginx UID ${NGINX_UID}'
"
