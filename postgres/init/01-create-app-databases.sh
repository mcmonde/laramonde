#!/bin/sh
# Creates one database + role per line in /apps.list.
# Format: app_name db_name db_user db_password
# Identifiers must be [A-Za-z_][A-Za-z0-9_]* — anything else is rejected.
set -eu

LIST="/apps.list"

if [ ! -f "$LIST" ]; then
  echo "postgres init: no apps.list, skipping per-app databases"
  exit 0
fi

is_ident() {
  echo "$1" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$'
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|\#*) continue ;;
  esac

  app=$(echo "$line" | awk '{print $1}')
  db=$(echo "$line" | awk '{print $2}')
  user=$(echo "$line" | awk '{print $3}')
  pass=$(echo "$line" | awk '{print $4}')

  if [ -z "$db" ] || [ -z "$user" ] || [ -z "$pass" ]; then
    echo "postgres init: skipping malformed line: $app"
    continue
  fi

  if ! is_ident "$db" || ! is_ident "$user"; then
    echo "postgres init: refusing unsafe identifier on line: $app"
    continue
  fi

  echo "postgres init: ensuring database $db owner $user"

  psql -v ON_ERROR_STOP=1 \
    --username "$POSTGRES_USER" \
    --dbname "$POSTGRES_DB" \
    --set=db="$db" \
    --set=dbuser="$user" \
    --set=dbpass="$pass" <<'SQL'
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
done < "$LIST"
