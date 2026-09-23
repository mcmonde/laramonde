#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="${1:-}"
USER="${2:-}"
PASS="${3:-}"

if [[ -z "$DB" || -z "$USER" || -z "$PASS" ]]; then
  echo "Usage: $0 <db_name> <db_user> <db_password>"
  echo "   or: ./dock db:create <app-name>"
  exit 1
fi

if [[ ! "$DB" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || [[ ! "$USER" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "Refusing unsafe identifier."
  exit 1
fi

docker compose --project-directory "$ROOT" -f "$ROOT/docker-compose.yml" exec -T postgres \
  psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" \
  --set=db="$DB" --set=dbuser="$USER" --set=dbpass="$PASS" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'dbuser', :'dbpass')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'dbuser')
\gexec

SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'dbuser')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db')
\gexec

SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'db')
\gexec

SELECT format('GRANT ALL ON DATABASE %I TO %I', :'db', :'dbuser')
\gexec
SQL

echo "Ensured database $DB owner $USER"
