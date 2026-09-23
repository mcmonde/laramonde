#!/usr/bin/env bash
# Merge profiles/<name>.env into root .env (overrides win).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/_lib.sh
source "$ROOT/scripts/_lib.sh"

NAME="${1:-}"
PROFILE="$ROOT/profiles/${NAME}.env"
ENV_FILE="$ROOT/.env"

if [[ -z "$NAME" || ! -f "$PROFILE" ]]; then
  echo "Usage: $0 <small|medium|large>"
  echo "Available:"
  ls -1 "$ROOT/profiles"/*.env 2>/dev/null | xargs -n1 basename | sed 's/\.env$//' | sed 's/^/  /'
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Run ./dock setup first."
  exit 1
fi

while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    ''|\#*) continue ;;
  esac
  key="${line%%=*}"
  value="${line#*=}"
  env_set "$key" "$value" "$ENV_FILE"
done < "$PROFILE"

env_set RESOURCE_PROFILE "$NAME" "$ENV_FILE"
sync_profile_env "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo "Applied resource profile: $NAME → $ENV_FILE"
echo "Scout/Mail synced from COMPOSE_PROFILES=$(profiles_csv || true)"
echo "Recreate containers to apply limits:"
echo "  ./dock up --force-recreate"
echo
if [[ "$NAME" == "small" ]]; then
  echo "Small-host tips:"
  echo "  - Run ONE app only (not hris+crms+api)."
  echo "  - Prefer PHP-FPM over Octane."
  echo "  - Set COMPOSE_PROFILES= (empty) to skip workspace/mailpit/meilisearch."
  echo "  - Enable search only when needed: COMPOSE_PROFILES=search then ./dock setup."
fi
