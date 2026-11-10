#!/usr/bin/env bash
# Report development or production from the root .env. Prints only the
# five host-mode keys. DOCK_ABOUT_ENV overrides the file for tests.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/_lib.sh
source "$ROOT/scripts/_lib.sh"

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s\n' "$s"
}

csv_has() {
  (
    local csv="$1" needle="$2" token
    local IFS=','
    set -f
    # shellcheck disable=SC2086
    for token in $csv; do
      token="$(trim "$token")"
      if [[ "$token" == "$needle" ]]; then
        exit 0
      fi
    done
    exit 1
  )
}

if [[ $# -gt 0 ]]; then
  echo "about does not take arguments. See ./dock help about." >&2
  exit 1
fi

env_file="${DOCK_ABOUT_ENV:-$ROOT/.env}"
if [[ ! -f "$env_file" ]]; then
  echo ".env is missing. Run ./dock setup or ./dock install."
  exit 1
fi

profiles="$(trim "$(env_get COMPOSE_PROFILES "$env_file")")"
nginx="$(trim "$(env_get NGINX_BIND "$env_file")")"
staging="$(trim "$(env_get CERTBOT_STAGING "$env_file")")"
meili="$(trim "$(env_get MEILI_ENV "$env_file")")"
resource_mode="$(trim "$(env_get RESOURCE_MODE "$env_file")")"

development=0
production=0
if csv_has "$profiles" dev && [[ "$nginx" == "127.0.0.1" ]]; then
  development=1
fi
if ! csv_has "$profiles" dev && ! csv_has "$profiles" mail \
  && [[ "$nginx" == "0.0.0.0" ]] && [[ "$staging" == "0" ]]; then
  production=1
fi

if [[ "$development" -eq 1 && "$production" -eq 1 ]]; then
  host="unrecognized"
elif [[ "$development" -eq 1 ]]; then
  host="development"
elif [[ "$production" -eq 1 ]]; then
  host="production"
else
  host="unrecognized"
fi

echo "Host: ${host}"
echo
if [[ "$host" == "unrecognized" ]]; then
  echo "This .env matches neither development nor production."
  echo "Development needs a dev profile and NGINX_BIND=127.0.0.1."
  echo "Production needs no dev or mail profile, NGINX_BIND=0.0.0.0, and CERTBOT_STAGING=0."
  echo
fi
printf '%s\n' \
  "COMPOSE_PROFILES=${profiles}" \
  "NGINX_BIND=${nginx}" \
  "CERTBOT_STAGING=${staging}" \
  "MEILI_ENV=${meili}" \
  "RESOURCE_MODE=${resource_mode}"

[[ "$host" != "unrecognized" ]]
