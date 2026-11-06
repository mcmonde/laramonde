#!/bin/sh
# Build a Redis ACL file, then start via the image entrypoint (drops to redis).
# The default user keeps the stack password so admin, workspace, and apps that
# were created before per-app users still authenticate. Per-app users are
# appended from /acl/apps.acl and can only touch their own key prefix.
set -eu

if [ -z "${REDIS_PASSWORD:-}" ]; then
  echo "redis: REDIS_PASSWORD is empty" >&2
  exit 1
fi

hash=$(printf '%s' "$REDIS_PASSWORD" | sha256sum | awk '{print $1}')
acl=/tmp/users.acl
{
  printf 'user default on #%s ~* &* +@all\n' "$hash"
  if [ -f /acl/apps.acl ]; then
    grep '^user ' /acl/apps.acl || true
  fi
} > "$acl"

if id redis >/dev/null 2>&1; then
  chown redis:redis "$acl"
fi
chmod 600 "$acl"

exec /usr/local/bin/docker-entrypoint.sh redis-server --aclfile "$acl" "$@"
