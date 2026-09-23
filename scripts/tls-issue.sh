#!/usr/bin/env bash
# Issue (or renew) a Let's Encrypt cert for an app and switch its nginx site to HTTPS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/_lib.sh
source "$ROOT/scripts/_lib.sh"

APP=""
STAGING=""
FORCE=0

usage() {
  cat <<'EOF'
Usage: tls-issue.sh <app-name> [--staging] [--force]

Issues a Let's Encrypt certificate for the app's APP_DOMAIN, renders the HTTPS
nginx config, fixes cert permissions for unprivileged nginx, and reloads nginx.

Examples:
  ./dock tls:issue hris
  ./dock tls:issue api --staging
  ./dock tls:issue hris --force
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --staging) STAGING="--staging"; shift ;;
    --force|-f) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      if [[ -z "$APP" ]]; then APP="$1"; else echo "Unexpected: $1"; usage; exit 1; fi
      shift
      ;;
  esac
done

if [[ -z "$APP" ]]; then
  usage
  exit 1
fi

require_app "$APP"

# shellcheck disable=SC1091
set -a
# shellcheck source=/dev/null
source "$ROOT/.env"
set +a

DOMAIN="$(app_domain "$APP")"
DEFAULTS="$(site_defaults "$APP")"

if [[ -z "$DOMAIN" || "$DOMAIN" == *.local ]]; then
  echo "APP_DOMAIN must be a real public hostname (got: '${DOMAIN}')."
  echo "Set it in $DEFAULTS then re-run."
  exit 1
fi

if [[ -z "${CERTBOT_EMAIL:-}" ]]; then
  echo "Set CERTBOT_EMAIL in .env first."
  exit 1
fi

if [[ "${NGINX_BIND:-127.0.0.1}" == "127.0.0.1" ]]; then
  echo "Warning: NGINX_BIND is 127.0.0.1 — Let's Encrypt cannot reach this host."
  echo "Set NGINX_BIND=0.0.0.0 in .env and ./dock up before continuing."
  if [[ "$FORCE" -ne 1 ]]; then
    exit 1
  fi
fi

# Prefer explicit --staging, else CERTBOT_STAGING=1 from .env
if [[ -z "$STAGING" && "${CERTBOT_STAGING:-1}" == "1" ]]; then
  STAGING="--staging"
  echo "Using Let's Encrypt staging (CERTBOT_STAGING=1). Pass production with CERTBOT_STAGING=0."
fi

# Ensure tls profile is enabled for renew loop
PROFILES="${COMPOSE_PROFILES:-}"
if [[ ",${PROFILES}," != *",tls,"* && "$PROFILES" != "tls" && "$PROFILES" != tls,* && "$PROFILES" != *,tls ]]; then
  if [[ -z "$PROFILES" ]]; then
    env_set COMPOSE_PROFILES "tls" "$ROOT/.env"
  else
    env_set COMPOSE_PROFILES "${PROFILES},tls" "$ROOT/.env"
  fi
  echo "Enabled COMPOSE_PROFILES+=tls in .env"
fi

echo "Ensuring nginx is up for ACME HTTP-01..."
"${COMPOSE[@]}" up -d nginx

# Keep ACME path working: ensure HTTP site exists before cert (TLS=0 first if switching fresh)
if [[ "$(app_tls "$APP")" != "1" ]]; then
  "$ROOT/scripts/render-site-nginx.sh" "$APP"
  nginx_reload || true
fi

CERTBOT_ARGS=(
  certonly
  --webroot -w /var/www/certbot
  --email "$CERTBOT_EMAIL"
  --agree-tos
  --no-eff-email
  --non-interactive
  -d "$DOMAIN"
)
if [[ -n "$STAGING" ]]; then
  CERTBOT_ARGS+=(--staging)
fi
if [[ "$FORCE" -eq 1 ]]; then
  CERTBOT_ARGS+=(--force-renewal)
fi

echo "Requesting certificate for ${DOMAIN}..."
"${COMPOSE[@]}" run --rm --entrypoint certbot --profile tls certbot "${CERTBOT_ARGS[@]}"

"$ROOT/scripts/tls-fix-certs.sh"

env_set APP_TLS 1 "$DEFAULTS"
env_set APP_URL "https://${DOMAIN}" "$DEFAULTS"
chmod 600 "$DEFAULTS"

"$ROOT/scripts/render-site-nginx.sh" "$APP"
nginx_reload

# Start renew loop
"${COMPOSE[@]}" --profile tls up -d certbot

echo
echo "TLS enabled for ${APP} → https://${DOMAIN}"
echo "  nginx conf : nginx/conf.d/sites/${APP}.conf"
echo "  Laravel    : merge sites/${APP}/.env.laravel.example (APP_URL/REVERB now https)"
echo
if [[ -n "$STAGING" ]]; then
  echo "This was a STAGING cert (browsers will warn). For production:"
  echo "  CERTBOT_STAGING=0 ./dock tls:issue ${APP} --force"
fi
echo "Renew later with: ./dock tls:renew"
