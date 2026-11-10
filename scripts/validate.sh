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

echo "== dock commands =="
# shellcheck source=scripts/_lib.sh
source "$ROOT/scripts/_lib.sh"

require_text() {
  local pattern="$1" text="$2"
  if ! grep -q -F -e "$pattern" <<<"$text"; then
    echo "expected text not found: ${pattern}" >&2
    exit 1
  fi
}

names_file="$(mktemp)"
{
  echo '  - path: sites/_template/compose.yml'
  echo '  # path: sites/ignored/compose.yml'
  echo '  - path: sites/_template_octane/compose.yml'
} > "$names_file"
[[ -z "$(registered_app_names "$names_file")" ]]
echo '  - path: sites/portal/compose.yml' >> "$names_file"
[[ "$(registered_app_names "$names_file")" == "portal" ]]
rm -f "$names_file"

env_existed=0
[[ -f .env ]] && env_existed=1
private_files=(docker-compose.yml publish.yml)
[[ -f .env ]] && private_files+=(.env)
before_private="$(sha256sum "${private_files[@]}" | sha256sum)"

list_out="$(./dock)"
if [[ "$list_out" != "$(./dock list)" || "$list_out" != "$(./dock help)" || "$list_out" != "$(./dock --help)" ]]; then
  echo "./dock, list, help, and --help should print the same command list" >&2
  exit 1
fi
require_text "about" "$list_out"
require_text "install [options]" "$list_out"
require_text "new-app <name> [host]" "$list_out"
require_text "setup [--rotate-secrets]" "$list_out"
if grep -q -F -e "Is this host" <<<"$list_out"; then
  echo "no-argument ./dock asked a first-install question" >&2
  exit 1
fi
if grep -q -F -e "passed through" <<<"$list_out"; then
  echo "unknown commands should fail instead of being passed to docker compose" >&2
  exit 1
fi
if [[ -z "$(registered_app_names)" ]]; then
  require_text "No apps yet" "$list_out"
elif grep -q -F -e "No apps yet" <<<"$list_out"; then
  echo "command list offered first install while apps are registered" >&2
  exit 1
fi

help_about="$(./dock help about)"
require_text "NGINX_BIND=127.0.0.1" "$help_about"
require_text "CERTBOT_STAGING=0" "$help_about"
help_install="$(./dock help install)"
require_text "--dry-run" "$help_install"
require_text "--no-interaction" "$help_install"
require_text "--env development|production" "$help_install"
new_help="$(./dock help new-app)"
require_text "--octane" "$new_help"
require_text "--skip-scale" "$new_help"
require_text "--force" "$new_help"
setup_help="$(./dock setup --help)"
require_text "--rotate-secrets" "$setup_help"

set +e
unknown="$(./dock not-a-command 2>&1)"
unknown_rc=$?
suggest="$(./dock newapp 2>&1)"
suggest_rc=$?
set -e
[[ "$unknown_rc" -eq 1 ]]
require_text "not defined" "$unknown"
require_text "./dock list" "$unknown"
[[ "$suggest_rc" -eq 1 ]]
require_text "new-app" "$suggest"

empty_compose="$(mktemp)"
printf '%s\n' '  - path: sites/_template/compose.yml' '  - path: sites/_template_octane/compose.yml' > "$empty_compose"
questions="$(DOCK_INSTALL_COMPOSE_FILE="$empty_compose" ./dock install --dry-run)"
require_text "Is this host for development or production?" "$questions"
require_text "Project name" "$questions"
require_text "latest Laravel" "$questions"
require_text "Nothing was written" "$questions"

dev_plan="$(DOCK_INSTALL_COMPOSE_FILE="$empty_compose" ./dock install --dry-run --no-interaction --env development --name portal --laravel)"
require_text "Host: development" "$dev_plan"
require_text "COMPOSE_PROFILES=dev,search" "$dev_plan"
require_text "NGINX_BIND=127.0.0.1" "$dev_plan"
require_text "CERTBOT_STAGING=1" "$dev_plan"
require_text "MEILI_ENV=development" "$dev_plan"
require_text "RESOURCE_MODE=auto" "$dev_plan"
require_text "create-project" "$dev_plan"
require_text "Dry run:" "$dev_plan"

prod_plan="$(DOCK_INSTALL_COMPOSE_FILE="$empty_compose" ./dock install --dry-run --no-interaction --env prod --name portal)"
require_text "Host: production" "$prod_plan"
require_text "COMPOSE_PROFILES=tls" "$prod_plan"
require_text "NGINX_BIND=0.0.0.0" "$prod_plan"
require_text "CERTBOT_STAGING=0" "$prod_plan"
require_text "MEILI_ENV=production" "$prod_plan"
require_text "RESOURCE_MODE=unlimited" "$prod_plan"
require_text "./dock new-app portal" "$prod_plan"
if grep -q -F -e "create-project" <<<"$prod_plan"; then
  echo "production plan included a Laravel install" >&2
  exit 1
fi

git_plan="$(DOCK_INSTALL_COMPOSE_FILE="$empty_compose" ./dock install --dry-run --no-interaction --env development --name portal-api --git 'https://user:secret@github.com/org/portal.git')"
require_text "https://github.com/org/portal.git" "$git_plan"
require_text "Project: portal-api" "$git_plan"
if grep -q -F -e "secret" <<<"$git_plan"; then
  echo "dry-run printed a git credential" >&2
  exit 1
fi

apps_compose="$(mktemp)"
printf '%s\n' '  - path: sites/_template/compose.yml' '  - path: sites/portal/compose.yml' > "$apps_compose"
skipped="$(DOCK_INSTALL_COMPOSE_FILE="$apps_compose" ./dock install --dry-run --env development --name other --laravel)"
require_text "questions are skipped" "$skipped"
require_text "portal" "$skipped"
if grep -q -F -e "COMPOSE_PROFILES" <<<"$skipped"; then
  echo "install with an app already registered printed a write plan" >&2
  exit 1
fi

set +e
third="$(DOCK_INSTALL_COMPOSE_FILE="$empty_compose" ./dock install --dry-run --no-interaction --env staging --name portal 2>&1)"
third_rc=$?
badname="$(DOCK_INSTALL_COMPOSE_FILE="$empty_compose" ./dock install --dry-run --no-interaction --env development --name Portal --laravel 2>&1)"
badname_rc=$?
prod_src="$(DOCK_INSTALL_COMPOSE_FILE="$empty_compose" ./dock install --dry-run --no-interaction --env production --name portal --laravel 2>&1)"
prod_src_rc=$?
ni="$(DOCK_INSTALL_COMPOSE_FILE="$empty_compose" timeout 5 ./dock install --no-interaction </dev/null 2>&1)"
ni_rc=$?
notty="$(DOCK_INSTALL_COMPOSE_FILE="$empty_compose" timeout 5 ./dock install </dev/null 2>&1)"
notty_rc=$?
set -e
[[ "$third_rc" -eq 1 ]]
require_text "development or production" "$third"
[[ "$badname_rc" -eq 1 ]]
[[ "$prod_src_rc" -eq 1 ]]
[[ "$ni_rc" -eq 1 ]]
require_text "non-interactive" "$ni"
[[ "$notty_rc" -eq 1 ]]
require_text "terminal" "$notty"
rm -f "$empty_compose" "$apps_compose"

about_env="$(mktemp)"
chmod 600 "$about_env"
cat > "$about_env" <<'EOF'
COMPOSE_PROFILES=dev,search
NGINX_BIND=127.0.0.1
CERTBOT_STAGING=0
MEILI_ENV=development
RESOURCE_MODE=unlimited
POSTGRES_PASSWORD=super-secret-value
EOF
about_dev="$(DOCK_ABOUT_ENV="$about_env" ./dock about)"
require_text "Host: development" "$about_dev"
require_text "COMPOSE_PROFILES=dev,search" "$about_dev"
require_text "NGINX_BIND=127.0.0.1" "$about_dev"
require_text "CERTBOT_STAGING=0" "$about_dev"
require_text "MEILI_ENV=development" "$about_dev"
require_text "RESOURCE_MODE=unlimited" "$about_dev"
if grep -q -F -e "super-secret-value" <<<"$about_dev" || grep -q -F -e "POSTGRES_PASSWORD" <<<"$about_dev"; then
  echo "about printed a secret" >&2
  exit 1
fi

cat > "$about_env" <<'EOF'
COMPOSE_PROFILES=tls,search
NGINX_BIND=0.0.0.0
CERTBOT_STAGING=0
MEILI_ENV=production
RESOURCE_MODE=auto
EOF
about_prod="$(DOCK_ABOUT_ENV="$about_env" ./dock about)"
require_text "Host: production" "$about_prod"
require_text "COMPOSE_PROFILES=tls,search" "$about_prod"
require_text "NGINX_BIND=0.0.0.0" "$about_prod"

printf '%s\n' 'COMPOSE_PROFILES=' 'NGINX_BIND=0.0.0.0' 'CERTBOT_STAGING=0' > "$about_env"
about_lean="$(DOCK_ABOUT_ENV="$about_env" ./dock about)"
require_text "Host: production" "$about_lean"

printf '%s\n' 'COMPOSE_PROFILES=dev,search' 'NGINX_BIND=0.0.0.0' 'CERTBOT_STAGING=0' > "$about_env"
set +e
about_mix="$(DOCK_ABOUT_ENV="$about_env" ./dock about 2>&1)"
about_mix_rc=$?
missing="$(DOCK_ABOUT_ENV="$about_env.absent" ./dock about 2>&1)"
missing_rc=$?
set -e
[[ "$about_mix_rc" -eq 1 ]]
require_text "Host: unrecognized" "$about_mix"
require_text "matches neither" "$about_mix"
require_text "COMPOSE_PROFILES=dev,search" "$about_mix"
[[ "$missing_rc" -eq 1 ]]
require_text ".env is missing" "$missing"
rm -f "$about_env"

after_private="$(sha256sum "${private_files[@]}" | sha256sum)"
if [[ "$before_private" != "$after_private" ]]; then
  echo "dock checks changed docker-compose.yml, publish.yml, or .env" >&2
  exit 1
fi
if [[ "$env_existed" -eq 0 && -f .env ]]; then
  echo "dock checks created .env" >&2
  exit 1
fi
echo "  ok dock"

echo "== install-extras copies =="
if ! cmp -s php-fpm/install-extras.sh php-octane/install-extras.sh; then
  echo "  php-fpm/install-extras.sh and php-octane/install-extras.sh differ — keep them identical"
  exit 1
fi
echo "  ok (identical)"

echo "== redis acl boot =="
sh -n redis/acl-boot.sh
echo "  ok redis/acl-boot.sh"

echo "== publish ports =="
"$ROOT/scripts/sync-publish.sh"

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
