#!/usr/bin/env bash
# List apps and their effective configuration (runtime, PHP, domain, limits, workers).
# Usage: apps.sh [app]
# Values resolve like Compose does: root .env > sites/<app>/defaults.env >
# php-fpm|php-octane/defaults.env > template/image default.
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

ENV_FILE="$ROOT/.env"

list_apps() {
  local d
  for d in "$ROOT"/sites/*/; do
    d="$(basename "$d")"
    [[ "$d" == _template* ]] && continue
    [[ -f "$ROOT/sites/$d/defaults.env" ]] && echo "$d"
  done
}

base_defaults() {
  if [[ "$(app_runtime "$1")" == "octane" ]]; then
    echo "$ROOT/php-octane/defaults.env"
  else
    echo "$ROOT/php-fpm/defaults.env"
  fi
}

# eff <app> <key> [fallback]
eff() {
  local app="$1" key="$2" fallback="${3:-}" v=""
  [[ -f "$ENV_FILE" ]] && v="$(env_get "$key" "$ENV_FILE")"
  [[ -z "$v" ]] && v="$(env_get "$key" "$(site_defaults "$app")")"
  [[ -z "$v" ]] && v="$(env_get "$key" "$(base_defaults "$app")")"
  echo "${v:-$fallback}"
}

# Where an effective value comes from (for the detail view).
src() {
  local app="$1" key="$2"
  if [[ -f "$ENV_FILE" && -n "$(env_get "$key" "$ENV_FILE")" ]]; then echo "root .env"
  elif [[ -n "$(env_get "$key" "$(site_defaults "$app")")" ]]; then echo "sites/$app/defaults.env"
  elif [[ -n "$(env_get "$key" "$(base_defaults "$app")")" ]]; then echo "$(basename "$(dirname "$(base_defaults "$app")")")/defaults.env"
  else echo "default"
  fi
}

compose_has() { grep -qE "$2" "$ROOT/sites/$1/compose.yml" 2>/dev/null; }

services_of() {
  local app="$1" s out=()
  for s in php octane queue scheduler reverb; do
    compose_has "$app" "^  ${app}-${s}:" && out+=("$s")
  done
  echo "${out[*]:-}"
}

cap() {
  local mem="$1" cpu="$2"
  if [[ "$mem" == "0" && "$cpu" == "0" ]]; then echo "none"; else echo "${mem}/${cpu}"; fi
}

# PHP memory_limit actually applied (old compose files don't pass the env var).
mem_limit() {
  local app="$1" img_default="256M"
  [[ "$(app_runtime "$app")" == "octane" ]] && img_default="512M"
  if compose_has "$app" "PHP_MEMORY_LIMIT:"; then eff "$app" PHP_MEMORY_LIMIT "$img_default"
  else echo "${img_default}*"
  fi
}

workers() {
  local app="$1" cmd
  if [[ "$(app_runtime "$app")" == "octane" ]]; then
    cmd="$(eff "$app" OCTANE_COMMAND)"
    [[ "$cmd" =~ --workers=([0-9]+) ]] && echo "${BASH_REMATCH[1]}" || echo "auto"
  elif compose_has "$app" "PHP_MAX_CHILDREN:"; then
    eff "$app" PHP_MAX_CHILDREN 8
  else
    echo "8*"
  fi
}

http_service() {
  if [[ "$(app_runtime "$1")" == "octane" ]]; then echo "OCTANE"; else echo "PHP"; fi
}

# name -> "State Status" for running containers of this compose project (empty if docker unavailable)
declare -A STATE=()
load_state() {
  local line
  while IFS=$'\t' read -r name state; do
    [[ -n "$name" ]] && STATE["$name"]="$state"
  done < <("${COMPOSE[@]}" ps -a --format '{{.Service}}\t{{.State}}' 2>/dev/null || true)
}

running_count() {
  local app="$1" s n=0 t=0
  for s in $(services_of "$app"); do
    t=$((t + 1))
    [[ "${STATE["$app-$s"]:-}" == "running" ]] && n=$((n + 1))
  done
  echo "$n/$t"
}

summary() {
  local apps=("$@") app fmt h
  fmt='%-14s %-7s %-4s %-9s %-4s %-30s %-11s %-8s %-7s %s\n'
  # shellcheck disable=SC2059
  printf "$fmt" APP RUNTIME PHP LAYOUT TLS DOMAIN "HTTP CAP" WORKERS MEMLIM UP
  for app in "${apps[@]}"; do
    h="$(http_service "$app")"
    # shellcheck disable=SC2059
    printf "$fmt" "$app" "$(app_runtime "$app")" "$(eff "$app" APP_PHP_VERSION "$(eff "$app" PHP_VERSION 8.4)")" \
      "$(app_layout "$app")" "$( [[ "$(app_tls "$app")" == "1" ]] && echo yes || echo no )" \
      "$(app_domain "$app")" "$(cap "$(eff "$app" "${h}_MEMORY" -)" "$(eff "$app" "${h}_CPUS" -)")" \
      "$(workers "$app")" "$(mem_limit "$app")" "$(running_count "$app")"
  done
  echo
  echo "HTTP CAP = container memory/cpus limit (none = unlimited). WORKERS = FPM pm.max_children or Octane --workers."
  echo "MEMLIM = PHP memory_limit. * = image default: this app's compose.yml predates the setting (see docs/03-apps.md)."
  echo "Details: ./dock apps <app>   Host plan: ./dock resources status"
}

detail() {
  local app="$1" h runtime suffix img s svc mem cpu state ext apt
  require_app "$app"
  runtime="$(app_runtime "$app")"
  h="$(http_service "$app")"
  suffix="$(eff "$app" APP_IMAGE_SUFFIX)"
  if [[ "$runtime" == "octane" ]]; then img="$(eff "$app" PHP_OCTANE_IMAGE multiapp-php-octane)"
  else img="$(eff "$app" PHP_IMAGE multiapp-php)"
  fi
  img="${img}:$(eff "$app" APP_PHP_VERSION "$(eff "$app" PHP_VERSION 8.4)")${suffix}"
  ext="$(eff "$app" APP_PHP_EXTENSIONS)"
  apt="$(eff "$app" APP_APT_PACKAGES)"

  echo "App: $app"
  echo "------------------------------------------------------------"
  printf '  %-18s %s\n' runtime "$runtime" \
    "PHP version" "$(eff "$app" APP_PHP_VERSION "$(eff "$app" PHP_VERSION 8.4)")" \
    image "$img" \
    "extras: ext" "${ext:-<none>}" \
    "extras: apt" "${apt:-<none>}" \
    domain "$(app_domain "$app")" \
    APP_URL "$(eff "$app" APP_URL)" \
    TLS "$( [[ "$(app_tls "$app")" == "1" ]] && echo on || echo off )" \
    layout "$(app_layout "$app")" \
    database "$(eff "$app" DB_DATABASE)" \
    "code" "apps/$app $( [[ -d "$ROOT/apps/$app" ]] && echo '' || echo '(missing)')" \
    "nginx conf" "nginx/conf.d/sites/$app.conf $( [[ -f "$ROOT/nginx/conf.d/sites/$app.conf" ]] && echo '' || echo '(missing)')" \
    "resource weight" "$(app_resource_weight "$app")$(app_resource_pinned "$app" && echo ' (pinned)' || true)" \
    "resource mode" "$(env_get RESOURCE_MODE "$ENV_FILE" 2>/dev/null || true)"
  echo
  echo "PHP"
  echo "------------------------------------------------------------"
  local unwired="(image default; sites/$app/compose.yml does not pass it — see docs/03-apps.md)"
  if compose_has "$app" "PHP_MEMORY_LIMIT:"; then
    printf '  %-18s %-10s %s\n' memory_limit "$(mem_limit "$app")" "($(src "$app" PHP_MEMORY_LIMIT))"
  else
    printf '  %-18s %-10s %s\n' memory_limit "$(mem_limit "$app")" "$unwired"
  fi
  if [[ "$runtime" == "octane" ]]; then
    printf '  %-18s %s\n' "octane command" "$(eff "$app" OCTANE_COMMAND)"
  elif compose_has "$app" "PHP_MAX_CHILDREN:"; then
    printf '  %-18s %-10s %s\n' pm.max_children "$(workers "$app")" "($(src "$app" PHP_MAX_CHILDREN))"
  else
    printf '  %-18s %-10s %s\n' pm.max_children "$(workers "$app")" "$unwired"
  fi
  printf '  %-18s %s\n' "queue command" "$(eff "$app" APP_QUEUE_COMMAND)"
  echo
  echo "Containers (memory/cpus limit; 0 = unlimited)"
  echo "------------------------------------------------------------"
  printf '  %-26s %-8s %-6s %-12s %s\n' SERVICE MEMORY CPUS STATE "SET IN"
  for s in $(services_of "$app"); do
    case "$s" in
      php|octane) svc="$h" ;;
      queue) svc=QUEUE ;;
      scheduler) svc=SCHEDULER ;;
      reverb) svc=REVERB ;;
    esac
    mem="$(eff "$app" "${svc}_MEMORY" -)"
    cpu="$(eff "$app" "${svc}_CPUS" -)"
    state="${STATE["$app-$s"]:-not created}"
    printf '  %-26s %-8s %-6s %-12s %s\n' "$app-$s" "$mem" "$cpu" "$state" "$(src "$app" "${svc}_MEMORY")"
  done

  # Live check of what PHP actually uses, when the HTTP container is running.
  s="php"; [[ "$runtime" == "octane" ]] && s="octane"
  if [[ "${STATE["$app-$s"]:-}" == "running" ]]; then
    echo
    echo "Live ($app-$s)"
    echo "------------------------------------------------------------"
    "${COMPOSE[@]}" exec -T "$app-$s" php -r 'printf("  %-18s %s\n  %-18s %s\n", "PHP", PHP_VERSION, "memory_limit", ini_get("memory_limit"));' 2>/dev/null \
      || echo "  (could not exec into $app-$s)"
    if [[ "$runtime" != "octane" ]]; then
      "${COMPOSE[@]}" exec -T "$app-$s" sh -c 'php-fpm -tt 2>&1 | grep -m1 -o "pm.max_children = [0-9]*"' 2>/dev/null \
        | sed 's/^/  /;s/ = /            /' || true
    fi
  fi
}

load_state
if [[ $# -gt 0 ]]; then
  detail "$1"
else
  mapfile -t APPS < <(list_apps)
  if [[ ${#APPS[@]} -eq 0 ]]; then
    echo "No apps yet — ./dock new-app <name> [domain]"
    exit 0
  fi
  summary "${APPS[@]}"
fi
