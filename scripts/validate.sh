#!/usr/bin/env bash
# Validate compose + shell scripts (safe to run in CI).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "== bash -n =="
bash -n dock
for f in scripts/*.sh; do
  bash -n "$f"
  echo "  ok $f"
done

echo "== docker compose config =="
if [[ ! -f .env ]]; then
  echo "No .env — copying .env.example for validation only"
  cp .env.example .env
  # Satisfy required vars without claiming these are production secrets
  ./scripts/setup.sh >/dev/null
fi
docker compose --project-directory "$ROOT" -f "$ROOT/docker-compose.yml" config >/dev/null
echo "  compose config OK"

echo "== profile env keys =="
# shellcheck source=scripts/_lib.sh
source "$ROOT/scripts/_lib.sh"
for key in SCOUT_DRIVER MEILISEARCH_HOST MAIL_MAILER MAIL_HOST MAIL_PORT; do
  val="$(env_get "$key" "$ROOT/.env" || true)"
  echo "  $key=${val:-<empty>}"
done

echo
echo "validate: OK"
