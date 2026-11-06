#!/usr/bin/env bash
# Per-app Redis users. Passwords are read from APP_REDIS_PASSWORD (never argv).
# Key patterns are <prefix>* where prefix is <app>_. Pub/sub stays open so
# Horizon and other unprefixed channels keep working; GET/SET of another
# app's keys does not.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/_lib.sh
source "$ROOT/scripts/_lib.sh"

ACL_DIR="$ROOT/redis/acl"
ACL_FILE="$ACL_DIR/apps.acl"

usage() {
  echo "Usage: APP_REDIS_PASSWORD=... redis-acl.sh add <user> <prefix>"
  echo "       redis-acl.sh del <user>"
  exit 1
}

redis_running() {
  "${COMPOSE[@]}" ps redis --status running --format '{{.Name}}' 2>/dev/null | grep -q .
}

write_user_line() {
  local user="$1" line="$2"
  mkdir -p "$ACL_DIR"
  touch "$ACL_FILE"
  chmod 600 "$ACL_FILE"
  local tmp
  tmp="$(mktemp "${ACL_FILE}.tmp.XXXXXX")"
  if [[ -s "$ACL_FILE" ]]; then
    awk -v u="$user" -v line="$line" '
      BEGIN { prefix = "user " u " "; replaced = 0 }
      index($0, prefix) == 1 { print line; replaced = 1; next }
      { print }
      END { if (!replaced) print line }
    ' "$ACL_FILE" > "$tmp"
  else
    printf '%s\n' "$line" > "$tmp"
  fi
  mv "$tmp" "$ACL_FILE"
  chmod 600 "$ACL_FILE"
}

delete_user_line() {
  local user="$1"
  [[ -f "$ACL_FILE" ]] || return 0
  local tmp
  tmp="$(mktemp "${ACL_FILE}.tmp.XXXXXX")"
  awk -v u="$user" '
    BEGIN { prefix = "user " u " " }
    index($0, prefix) == 1 { next }
    { print }
  ' "$ACL_FILE" > "$tmp"
  mv "$tmp" "$ACL_FILE"
  chmod 600 "$ACL_FILE"
}

cmd_add() {
  local user="${1:-}" prefix="${2:-}" pass="${APP_REDIS_PASSWORD:-}"
  if [[ -z "$user" || -z "$prefix" || -z "$pass" ]]; then
    usage
  fi
  if [[ ! "$user" =~ ^app:[a-z][a-z0-9-]*$ ]]; then
    echo "Refusing Redis ACL user: ${user}" >&2
    exit 1
  fi
  # Prefix is "<app>_". The ACL pattern is that string plus *, which does not
  # match a longer app name (app names cannot contain '_').
  if [[ ! "$prefix" =~ ^[a-z][a-z0-9-]*_$ ]]; then
    echo "Refusing Redis key prefix." >&2
    exit 1
  fi

  local hash line
  hash="$(printf '%s' "$pass" | sha256sum | awk '{print $1}')"
  line="user ${user} on #${hash} ~${prefix}* &* +@all -@admin -@dangerous"
  write_user_line "$user" "$line"

  if ! redis_running; then
    echo "Redis ACL user ${user} saved for the next Redis start."
    return 0
  fi

  local master out
  master="$(env_get REDIS_PASSWORD "$ROOT/.env")"
  if [[ -z "$master" ]]; then
    echo "REDIS_PASSWORD is empty; cannot load the ACL user into the running Redis." >&2
    exit 1
  fi
  if ! out="$("${COMPOSE[@]}" exec -T -e REDISCLI_AUTH="$master" redis \
    redis-cli --no-auth-warning \
    ACL SETUSER "$user" reset on "#${hash}" "~${prefix}*" "&*" "+@all" "-@admin" "-@dangerous" 2>&1)"; then
    echo "Redis refused the per-app ACL user ${user}." >&2
    printf '%s\n' "$out" | sed -E 's/#?[0-9a-f]{32,}/<redacted>/g' >&2
    exit 1
  fi
  echo "Redis ACL user ${user} loaded (prefix ${prefix}*)."
}

cmd_del() {
  local user="${1:-}"
  if [[ ! "$user" =~ ^app:[a-z][a-z0-9-]*$ ]]; then
    echo "Refusing Redis ACL user: ${user}" >&2
    exit 1
  fi
  delete_user_line "$user"
  if ! redis_running; then
    echo "Removed Redis ACL user ${user} from redis/acl/apps.acl."
    return 0
  fi
  local master
  master="$(env_get REDIS_PASSWORD "$ROOT/.env")"
  if [[ -z "$master" ]]; then
    echo "Removed Redis ACL user ${user} from the file. Redis is up but REDIS_PASSWORD is empty, so the live user was not deleted." >&2
    exit 1
  fi
  "${COMPOSE[@]}" exec -T -e REDISCLI_AUTH="$master" redis \
    redis-cli --no-auth-warning ACL DELUSER "$user" >/dev/null 2>&1 || true
  echo "Removed Redis ACL user ${user}."
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    add) cmd_add "$@" ;;
    del) cmd_del "$@" ;;
    *) usage ;;
  esac
}

main "$@"
