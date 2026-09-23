#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT/backups/postgres"
STAMP="$(date +%Y%m%d_%H%M%S)"
FILE="$OUT_DIR/postgres_${STAMP}.sql.gz"

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

docker compose --project-directory "$ROOT" -f "$ROOT/docker-compose.yml" exec -T postgres \
  pg_dumpall -U "${POSTGRES_USER:-postgres}" | gzip > "$FILE"

chmod 600 "$FILE"
echo "Wrote $FILE"
