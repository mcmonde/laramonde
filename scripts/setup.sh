#!/usr/bin/env bash
# Create .env, generate strong secrets, sync profile-driven Scout/Mail, apply resources.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/_lib.sh
source "$ROOT/scripts/_lib.sh"

ENV_FILE="$ROOT/.env"
EXAMPLE="$ROOT/.env.example"
ROTATE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rotate-secrets|--rotate) ROTATE=1; shift ;;
    -h|--help)
      echo "Usage: setup.sh [--rotate-secrets]"
      echo "  Creates .env from .env.example if missing."
      echo "  Generates strong hex secrets for weak/placeholder values."
      echo "  --rotate-secrets  Force-regenerate POSTGRES/REDIS/MEILI secrets."
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

ensure_secret() {
  local key="$1"
  local min_len="${2:-32}"
  local bytes="${3:-48}"
  local current label

  current="$(env_get "$key" "$ENV_FILE")"
  if [[ "$ROTATE" -eq 1 ]] || is_weak_secret "$current" "$min_len"; then
    env_set "$key" "$(rand_hex "$bytes")" "$ENV_FILE"
    if [[ "$ROTATE" -eq 1 ]]; then
      label="Rotated"
    else
      label="Generated"
    fi
    echo "${label} ${key} (${bytes} bytes / $((bytes * 2)) hex chars)"
  else
    echo "Keeping ${key} (length ${#current})"
  fi
}

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$EXAMPLE" "$ENV_FILE"
  echo "Created $ENV_FILE from .env.example"
fi

# Postgres/Redis: ≥32 hex chars. Meili: master key must be ≥16; we use 32 bytes.
ensure_secret POSTGRES_PASSWORD 32 48
ensure_secret REDIS_PASSWORD 32 48
ensure_secret MEILI_MASTER_KEY 16 32

uid="$(id -u)"
if [[ "$uid" != "0" ]]; then
  env_set APP_UID "$uid" "$ENV_FILE"
  env_set APP_GID "$(id -g)" "$ENV_FILE"
fi

sync_profile_env "$ENV_FILE"
echo "Synced Scout/Mail env from COMPOSE_PROFILES=$(profiles_csv || true)"

chmod 600 "$ENV_FILE"

mkdir -p "$ROOT/certbot/www" "$ROOT/nginx/conf.d/sites" "$ROOT/apps" "$ROOT/backups/postgres" "$ROOT/logs"
touch "$ROOT/postgres/apps.list"
chmod 600 "$ROOT/postgres/apps.list" 2>/dev/null || true

# Guard: refuse to leave placeholder secrets behind
for key in POSTGRES_PASSWORD REDIS_PASSWORD MEILI_MASTER_KEY; do
  if is_weak_secret "$(env_get "$key" "$ENV_FILE")" 16; then
    echo "ERROR: ${key} is still weak after setup — aborting."
    exit 1
  fi
done

echo
echo "Detecting host and applying resource limits…"
"$ROOT/scripts/resources.sh" assess || true
"$ROOT/scripts/resources.sh" apply || true

echo
echo "Setup complete. Next:"
echo "  ./dock up"
echo "  ./dock new-app portal            # auto-checks capacity first"
echo "  ./dock resources assess        # re-check host anytime"
echo
echo "Secrets: ./dock setup --rotate-secrets   # regenerate stack passwords"
echo ".env is mode 600. Do not commit it."
if [[ "$ROTATE" -eq 1 ]]; then
  echo
  echo "NOTE: rotated secrets require recreating DB/Redis/Meili volumes if they"
  echo "already started with the old password, or update credentials in-place."
fi
