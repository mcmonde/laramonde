#!/usr/bin/env bash
# Shared helpers for site/TLS/setup/resource scripts.
# shellcheck shell=bash

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose --project-directory "$ROOT" -f "$ROOT/docker-compose.yml")

# ---- secrets -----------------------------------------------------------------

# Hex-only secrets are env-safe (no = / + / newlines) and high entropy.
rand_hex() {
  local bytes="${1:-32}"
  openssl rand -hex "$bytes"
}

# Default stack secret: 48 bytes → 96 hex chars.
rand_secret() {
  rand_hex 48
}

# Returns 0 if the value should be replaced (weak / placeholder / too short).
is_weak_secret() {
  local value="$1"
  local min_len="${2:-32}"
  local lower unique

  if [[ -z "$value" ]]; then
    return 0
  fi
  if [[ ${#value} -lt $min_len ]]; then
    return 0
  fi

  lower="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    change-me*|changeme*|password*|secret*|postgres|redis|admin|root|test*|example*|default*|toor|letmein|passw0rd*)
      return 0
      ;;
  esac

  unique="$(printf '%s' "$value" | fold -w1 | sort -u | wc -l | tr -d ' ')"
  if [[ "$unique" -lt 8 ]]; then
    return 0
  fi
  return 1
}

# ---- env files ---------------------------------------------------------------

env_get() {
  local key="$1" file="$2"
  grep -E "^${key}=" "$file" 2>/dev/null | head -n1 | cut -d= -f2-
}

# Replace or append KEY=value. Safe when values contain '=' (unlike FS="=" awk).
env_set() {
  local key="$1" value="$2" file="$3"
  if [[ ! -f "$file" ]]; then
    printf '%s=%s\n' "$key" "$value" > "$file"
    return
  fi
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    awk -v k="$key" -v v="$value" '
      BEGIN { prefix = k "=" }
      index($0, prefix) == 1 { print prefix v; next }
      { print }
    ' "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

# Remove KEY=... lines from an env file (no-op if missing).
env_unset() {
  local key="$1" file="$2"
  [[ -f "$file" ]] || return 0
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    awk -v k="$key" '
      BEGIN { prefix = k "=" }
      index($0, prefix) == 1 { next }
      { print }
    ' "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"
  fi
}

# ---- profiles / optional services --------------------------------------------

profiles_csv() {
  if [[ -f "$ROOT/.env" ]]; then
    env_get COMPOSE_PROFILES "$ROOT/.env"
  else
    echo ""
  fi
}

profile_has() {
  local needle="$1"
  local profiles
  profiles="$(profiles_csv)"
  [[ -z "$profiles" ]] && return 1
  [[ ",${profiles}," == *",${needle},"* ]] || [[ "$profiles" == "$needle" ]]
}

# Wire Scout/Mail env from COMPOSE_PROFILES so apps don't require Meili/Mailpit
# when those profiles are off.
sync_profile_env() {
  local env_file="${1:-$ROOT/.env}"
  [[ -f "$env_file" ]] || return 0

  if profile_has search; then
    env_set SCOUT_DRIVER meilisearch "$env_file"
    env_set MEILISEARCH_HOST http://meilisearch:7700 "$env_file"
  else
    env_set SCOUT_DRIVER null "$env_file"
    env_set MEILISEARCH_HOST "" "$env_file"
  fi

  if profile_has dev || profile_has mail; then
    env_set MAIL_MAILER smtp "$env_file"
    env_set MAIL_HOST mailpit "$env_file"
    env_set MAIL_PORT 1025 "$env_file"
  else
    env_set MAIL_MAILER log "$env_file"
    env_set MAIL_HOST "" "$env_file"
    env_set MAIL_PORT 2525 "$env_file"
  fi
}

# ---- apps --------------------------------------------------------------------

site_defaults() {
  echo "$ROOT/sites/$1/defaults.env"
}

require_app() {
  local app="$1"
  if [[ ! -f "$(site_defaults "$app")" ]]; then
    echo "Unknown app: $app (missing sites/${app}/defaults.env). Run ./dock new-app first."
    exit 1
  fi
}

app_runtime() {
  local v
  v="$(env_get APP_RUNTIME "$(site_defaults "$1")")"
  echo "${v:-fpm}"
}

app_domain() {
  env_get APP_DOMAIN "$(site_defaults "$1")"
}

app_tls() {
  local v
  v="$(env_get APP_TLS "$(site_defaults "$1")")"
  echo "${v:-0}"
}

# standard = Laravel at / ; spa = SPA at / (frontend/dist), Laravel at /api/ , Reverb at /app
app_layout() {
  local v
  v="$(env_get APP_LAYOUT "$(site_defaults "$1")")"
  echo "${v:-standard}"
}

app_resource_weight() {
  local v
  v="$(env_get RESOURCE_WEIGHT "$(site_defaults "$1")")"
  if [[ -z "$v" ]]; then
    echo "1"
  else
    echo "$v"
  fi
}

app_resource_pinned() {
  local v
  v="$(env_get RESOURCE_PIN "$(site_defaults "$1")")"
  [[ "$v" == "1" || "$v" == "true" || "$v" == "yes" ]]
}

# Effective surplus weight (user weight × 1.25 if octane)
app_effective_weight() {
  local app="$1"
  local w runtime
  w="$(app_resource_weight "$app")"
  runtime="$(app_runtime "$app")"
  if [[ "$runtime" == "octane" ]]; then
    awk -v w="$w" 'BEGIN{printf "%.2f", w*1.25}'
  else
    echo "$w"
  fi
}

nginx_reload() {
  if "${COMPOSE[@]}" ps nginx --status running --format '{{.Name}}' 2>/dev/null | grep -q .; then
    "${COMPOSE[@]}" exec -T nginx nginx -t
    "${COMPOSE[@]}" exec -T nginx nginx -s reload
    echo "nginx reloaded"
  else
    echo "nginx is not running — start with ./dock up"
  fi
}

prompt_continue() {
  local msg="$1"
  if [[ "${RESOURCES_ASSUME_YES:-0}" == "1" ]]; then
    echo "$msg (RESOURCES_ASSUME_YES=1 — continuing)"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "$msg"
    echo "Non-interactive session: treating as NO. Re-run with --force or RESOURCES_ASSUME_YES=1."
    return 1
  fi
  local ans
  read -r -p "$msg [y/N] " ans || true
  [[ "${ans:-}" =~ ^[Yy]$ ]]
}
