#!/usr/bin/env bash
# Show TLS status for all (or one) apps.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/_lib.sh
source "$ROOT/scripts/_lib.sh"

FILTER="${1:-}"

printf '%-16s %-8s %-8s %-8s %s\n' "APP" "RUNTIME" "LAYOUT" "TLS" "DOMAIN"
printf '%-16s %-8s %-8s %-8s %s\n' "---" "-------" "------" "---" "------"

for defaults in "$ROOT"/sites/*/defaults.env; do
  [[ -f "$defaults" ]] || continue
  app="$(basename "$(dirname "$defaults")")"
  [[ "$app" == _template* ]] && continue
  if [[ -n "$FILTER" && "$app" != "$FILTER" ]]; then
    continue
  fi
  runtime="$(env_get APP_RUNTIME "$defaults")"
  layout="$(env_get APP_LAYOUT "$defaults")"
  tls="$(env_get APP_TLS "$defaults")"
  domain="$(env_get APP_DOMAIN "$defaults")"
  printf '%-16s %-8s %-8s %-8s %s\n' "$app" "${runtime:-fpm}" "${layout:-standard}" "${tls:-0}" "${domain:-}"
done
