#!/usr/bin/env bash
# First install: host mode, project name, then setup, up, and the first app.
# Asks only when docker-compose.yml has no sites/<app>/compose.yml include
# (template directories whose names start with _ are ignored).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/_lib.sh
source "$ROOT/scripts/_lib.sh"

MODE_RAW=""
MODE=""
APP_NAME=""
SOURCE=""
GIT_URL=""
DRY=0
NO_INTERACTION=0

die() {
  echo "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: install.sh [options]

First install when no app is included in docker-compose.yml.
Template includes (sites/_template, sites/_template_octane) do not count.
A later run with an app included does not ask and does not change .env.

  --env development|production   Host mode (dev and prod are accepted)
  --name <app>                   First app name (./dock new-app rules)
  --laravel                      Development: latest Laravel into apps/<name>
  --git <url>                    Development: clone this repository into apps/<name>
  --no-interaction, -n           Do not ask; require the flags above
  --dry-run                      Print the questions or the plan; write nothing

Development writes the .env.example host values:
  COMPOSE_PROFILES=dev,search
  NGINX_BIND=127.0.0.1
  CERTBOT_STAGING=1
  MEILI_ENV=development
  RESOURCE_MODE=auto

Production writes the production-guide host values:
  COMPOSE_PROFILES=tls
  NGINX_BIND=0.0.0.0
  CERTBOT_STAGING=0
  MEILI_ENV=production
  RESOURCE_MODE=unlimited

DOCK_INSTALL_COMPOSE_FILE  Read includes from this file instead of docker-compose.yml.
EOF
}

normalize_host_mode() {
  local raw="${1,,}"
  case "$raw" in
    development|dev) printf '%s\n' development ;;
    production|prod) printf '%s\n' production ;;
    *) return 1 ;;
  esac
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s\n' "$s"
}

valid_git_remote() {
  local url="$1" ch
  local -a blocked=( ';' '|' '&' '`' '$' '<' '>' '(' ')' '{' '}' "'" '"' )
  [[ -n "$url" ]] || return 1
  [[ ${#url} -le 2000 ]] || return 1
  [[ "$url" != *$'\n'* && "$url" != *$'\r'* && "$url" != *$'\t'* ]] || return 1
  [[ ! "$url" =~ [[:space:]] ]] || return 1
  for ch in "${blocked[@]}"; do
    if [[ "$url" == *"$ch"* ]]; then
      return 1
    fi
  done
  return 0
}

# Hide userinfo (tokens) so a URL can be printed.
redact_git_url() {
  local url="$1"
  if [[ "$url" =~ ^([A-Za-z][A-Za-z0-9+.-]*)://[^/@[:space:]]+@(.+)$ ]]; then
    printf '%s://%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf '%s\n' "$url"
  fi
}

host_mode_lines() {
  case "$1" in
    development)
      printf '%s\n' \
        'COMPOSE_PROFILES=dev,search' \
        'NGINX_BIND=127.0.0.1' \
        'CERTBOT_STAGING=1' \
        'MEILI_ENV=development' \
        'RESOURCE_MODE=auto'
      ;;
    production)
      printf '%s\n' \
        'COMPOSE_PROFILES=tls' \
        'NGINX_BIND=0.0.0.0' \
        'CERTBOT_STAGING=0' \
        'MEILI_ENV=production' \
        'RESOURCE_MODE=unlimited'
      ;;
    *)
      return 1
      ;;
  esac
}

compose_path() {
  if [[ -n "${DOCK_INSTALL_COMPOSE_FILE:-}" ]]; then
    if [[ ! -f "$DOCK_INSTALL_COMPOSE_FILE" ]]; then
      die "DOCK_INSTALL_COMPOSE_FILE is not a file."
    fi
    printf '%s\n' "$DOCK_INSTALL_COMPOSE_FILE"
  else
    printf '%s\n' "$ROOT/docker-compose.yml"
  fi
}

app_names() {
  registered_app_names "$(compose_path)"
}

prompt_line() {
  local text="$1" reply
  if [[ "$NO_INTERACTION" -eq 1 || ! -t 0 ]]; then
    echo "This question needs a terminal: ${text}" >&2
    echo "Re-run with --no-interaction and the flags from './dock help install'." >&2
    return 1
  fi
  if ! IFS= read -r -p "${text} " reply; then
    echo >&2
    echo "Aborted." >&2
    return 1
  fi
  printf '%s\n' "$reply"
}

ask_mode() {
  local reply norm
  while true; do
    reply="$(prompt_line "Is this host for development or production? [development/production]")" || return 1
    reply="$(trim "$reply")"
    if norm="$(normalize_host_mode "$reply")"; then
      MODE="$norm"
      return 0
    fi
    echo "Answer development or production."
  done
}

ask_name() {
  local reply
  while true; do
    reply="$(prompt_line "Project name:")" || return 1
    reply="$(trim "$reply")"
    if valid_app_name "$reply"; then
      APP_NAME="$reply"
      return 0
    fi
    echo "Use a lowercase letter, then lowercase letters, digits, or hyphens."
  done
}

ask_git() {
  local reply
  while true; do
    reply="$(prompt_line "Git repository URL:")" || return 1
    reply="$(trim "$reply")"
    if valid_git_remote "$reply"; then
      GIT_URL="$reply"
      SOURCE="git"
      return 0
    fi
    echo "Give a git URL or path with no spaces."
  done
}

ask_source() {
  local reply
  while true; do
    echo "How should apps/${APP_NAME} be filled?"
    echo "  1) Install the latest Laravel"
    echo "  2) Clone a git repository"
    reply="$(prompt_line "Choice [1/2]:")" || return 1
    reply="$(trim "$reply")"
    reply="${reply,,}"
    case "$reply" in
      1|laravel)
        SOURCE="laravel"
        return 0
        ;;
      2|git)
        ask_git || return 1
        return 0
        ;;
      *)
        echo "Answer 1 or 2."
        ;;
    esac
  done
}

answers_complete() {
  [[ -n "$MODE" && -n "$APP_NAME" ]] || return 1
  if [[ "$MODE" == "development" ]]; then
    [[ "$SOURCE" == "laravel" || ( "$SOURCE" == "git" && -n "$GIT_URL" ) ]]
  else
    [[ -z "$SOURCE" ]]
  fi
}

print_questions() {
  if [[ -n "$MODE" || -n "$APP_NAME" || -n "$SOURCE" ]]; then
    echo "Provided:"
    [[ -n "$MODE" ]] && echo "  host: ${MODE}"
    [[ -n "$APP_NAME" ]] && echo "  project: ${APP_NAME}"
    if [[ "$SOURCE" == "laravel" ]]; then
      echo "  source: latest Laravel"
    elif [[ "$SOURCE" == "git" ]]; then
      echo "  source: git clone $(redact_git_url "$GIT_URL")"
    fi
    echo
  fi
  cat <<'EOF'
No apps are registered (no sites/<app>/compose.yml include; template names starting with _ are ignored).

First install would ask:
  1. Is this host for development or production?
  2. Project name (the first app: a lowercase letter, then lowercase letters, digits, or hyphens)
  3. In development: install the latest Laravel into apps/<name>, or clone a git repository you give
     Production skips question 3.

Nothing was written. Preview a plan:
  ./dock install --dry-run --no-interaction --env development --name portal --laravel
  ./dock install --dry-run --no-interaction --env development --name portal --git git@github.com:org/portal.git
  ./dock install --dry-run --no-interaction --env production --name portal

Run it without prompts:
  ./dock install --no-interaction --env development --name portal --laravel
  ./dock install --no-interaction --env production --name portal
EOF
}

print_plan() {
  local dry="$1" shown=""
  echo "Host: ${MODE}"
  echo "Project: ${APP_NAME}"
  if [[ "$MODE" == "development" && "$SOURCE" == "laravel" ]]; then
    echo "Code: latest Laravel into apps/${APP_NAME}"
  elif [[ "$MODE" == "development" && "$SOURCE" == "git" ]]; then
    shown="$(redact_git_url "$GIT_URL")"
    echo "Code: git clone ${shown} into apps/${APP_NAME}"
  else
    echo "Code: left for deploy in apps/${APP_NAME} (production skips the source question)"
  fi
  echo
  echo ".env:"
  host_mode_lines "$MODE" | sed 's/^/  /'
  echo
  if [[ "$MODE" == "production" ]]; then
    echo "On a small host, RESOURCE_MODE=unlimited is the production default. On a larger host, set RESOURCE_MODE=auto and run ./dock resources apply."
    echo
  fi
  echo "Then:"
  echo "  ./dock setup"
  echo "  ./dock up"
  echo "  ./dock new-app ${APP_NAME}"
  if [[ "$SOURCE" == "laravel" ]]; then
    echo "  composer create-project laravel/laravel apps/${APP_NAME} --no-interaction --prefer-dist"
    echo "    (workspace container)"
  elif [[ "$SOURCE" == "git" ]]; then
    echo "  git clone ${shown} apps/${APP_NAME}"
  fi
  if [[ "$dry" -eq 1 ]]; then
    echo
    echo "Dry run: nothing was written and no containers were started."
  fi
}

apply_host_mode() {
  local env_file="$ROOT/.env" line key value
  if [[ ! -f "$env_file" ]]; then
    (umask 077; cp "$ROOT/.env.example" "$env_file")
    chmod 600 "$env_file"
    echo "Created .env from .env.example"
  fi
  while IFS= read -r line; do
    key="${line%%=*}"
    value="${line#*=}"
    env_set "$key" "$value" "$env_file"
  done < <(host_mode_lines "$MODE")
  echo "Wrote host mode ${MODE} into .env:"
  host_mode_lines "$MODE" | sed 's/^/  /'
}

run() {
  echo "+ $*"
  "$@"
}

app_code_ready_for_fill() {
  local dir="$1" f base
  [[ -d "$dir" ]] || return 1
  for f in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    [[ "$base" == ".gitkeep" ]] && continue
    return 1
  done
  return 0
}

code_dir() {
  printf '%s\n' "$ROOT/apps/${APP_NAME}"
}

workspace_matches_apps() {
  local host_code resolved apps_dir
  host_code="$(env_get APP_CODE_PATH_HOST "$ROOT/.env")"
  host_code="${host_code:-./apps}"
  host_code="${host_code%/}"
  if [[ "$host_code" == /* ]]; then
    resolved="$host_code"
  else
    resolved="$ROOT/${host_code#./}"
  fi
  apps_dir="$(cd "$ROOT/apps" && pwd)"
  resolved="$(cd "$resolved" 2>/dev/null && pwd || true)"
  [[ -n "$resolved" && "$resolved" == "$apps_dir" ]]
}

fill_laravel() {
  local dir container
  dir="$(code_dir)"
  if ! workspace_matches_apps; then
    echo "APP_CODE_PATH_HOST does not point at ./apps, so the workspace container cannot see apps/${APP_NAME}." >&2
    echo "Install Laravel into apps/${APP_NAME} on the host, or set APP_CODE_PATH_HOST=./apps and run the create-project again." >&2
    return 1
  fi
  if ! app_code_ready_for_fill "$dir"; then
    echo "apps/${APP_NAME} already has files. Leaving them in place." >&2
    echo "The app is already registered, so a later ./dock install will not ask again." >&2
    return 1
  fi
  local running
  running="$("${COMPOSE[@]}" ps workspace --status running --format '{{.Name}}' 2>/dev/null || true)"
  if [[ -z "$running" ]]; then
    echo "The workspace container is not running, so Laravel was not installed." >&2
    echo "The app is already registered, so a later ./dock install will not ask again." >&2
    echo "Start the dev profile (./dock up), then run composer create-project laravel/laravel inside the workspace container." >&2
    return 1
  fi
  container="$(env_get APP_CODE_PATH_CONTAINER "$ROOT/.env")"
  container="${container:-/var/www/apps}"
  container="${container%/}/${APP_NAME}"
  rm -f "$dir/.gitkeep"
  echo "+ docker compose exec -T workspace composer create-project laravel/laravel ${container} --no-interaction --prefer-dist"
  "${COMPOSE[@]}" exec -T -e COMPOSER_NO_INTERACTION=1 workspace \
    composer create-project laravel/laravel "$container" --no-interaction --prefer-dist
}

fill_git() {
  local dir shown
  dir="$(code_dir)"
  shown="$(redact_git_url "$GIT_URL")"
  if ! command -v git >/dev/null 2>&1; then
    echo "git is required to clone the repository." >&2
    return 1
  fi
  if ! app_code_ready_for_fill "$dir"; then
    echo "apps/${APP_NAME} already has files. Leaving them in place." >&2
    echo "The app is already registered, so a later ./dock install will not ask again." >&2
    echo "Clone by hand: git clone ${shown} apps/${APP_NAME}" >&2
    return 1
  fi
  rm -f "$dir/.gitkeep"
  echo "+ git clone ${shown} apps/${APP_NAME}"
  GIT_TERMINAL_PROMPT=0 \
    GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3}" \
    git clone "$GIT_URL" "$dir"
}

print_next() {
  echo
  echo "First install finished."
  echo "  host   : ${MODE}"
  echo "  app    : ${APP_NAME}"
  echo "  domain : ${APP_NAME}.local"
  echo "  nginx  : nginx/conf.d/sites/${APP_NAME}.conf"
  if [[ "$SOURCE" == "laravel" ]]; then
    echo "  code   : apps/${APP_NAME} (latest Laravel)"
  elif [[ "$SOURCE" == "git" ]]; then
    echo "  code   : apps/${APP_NAME} (git clone)"
  else
    echo "  code   : apps/${APP_NAME} (put the Laravel app here)"
  fi
  echo
  echo "Next:"
  if [[ "$MODE" == "development" ]]; then
    echo "  echo \"127.0.0.1 ${APP_NAME}.local\" | sudo tee -a /etc/hosts"
  else
    echo "  Set APP_DOMAIN and APP_URL in sites/${APP_NAME}/defaults.env, then ./dock site:render ${APP_NAME}"
    echo "  Set CERTBOT_EMAIL in .env before ./dock tls:issue ${APP_NAME}"
    echo "  On a larger host, set RESOURCE_MODE=auto and run ./dock resources apply"
  fi
  echo "  Merge sites/${APP_NAME}/.env.laravel.example into apps/${APP_NAME}/.env"
  echo "  ./dock artisan ${APP_NAME} key:generate && ./dock artisan ${APP_NAME} migrate"
}

execute() {
  if [[ "$NO_INTERACTION" -eq 1 ]]; then
    export DOCK_NO_INTERACTION=1
  fi
  apply_host_mode
  echo
  run "$ROOT/scripts/setup.sh"
  echo
  run "${COMPOSE[@]}" up -d
  echo
  run "$ROOT/scripts/new-app.sh" "$APP_NAME"
  if [[ "$SOURCE" == "laravel" ]]; then
    echo
    fill_laravel
  elif [[ "$SOURCE" == "git" ]]; then
    echo
    fill_git
  fi
  print_next
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY=1; shift ;;
      --no-interaction|-n) NO_INTERACTION=1; shift ;;
      --laravel) SOURCE="laravel"; shift ;;
      --env)
        [[ $# -ge 2 ]] || die "--env needs development or production."
        MODE_RAW="$2"
        shift 2
        ;;
      --env=*) MODE_RAW="${1#--env=}"; shift ;;
      --name)
        [[ $# -ge 2 ]] || die "--name needs an app name."
        APP_NAME="$2"
        shift 2
        ;;
      --name=*) APP_NAME="${1#--name=}"; shift ;;
      --git)
        [[ $# -ge 2 ]] || die "--git needs a repository URL."
        GIT_URL="$2"
        shift 2
        ;;
      --git=*) GIT_URL="${1#--git=}"; shift ;;
      -h|--help) usage; exit 0 ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        die "Unexpected argument: $1"
        ;;
    esac
  done
  if [[ -n "$GIT_URL" && "$SOURCE" == "laravel" ]]; then
    die "Use either --laravel or --git."
  fi
  if [[ -n "$GIT_URL" ]]; then
    SOURCE="git"
  fi
}

validate_flags() {
  local norm
  if [[ -n "$MODE_RAW" ]]; then
    if ! norm="$(normalize_host_mode "$MODE_RAW")"; then
      die "Host mode must be development or production."
    fi
    MODE="$norm"
  fi
  if [[ -n "$APP_NAME" ]] && ! valid_app_name "$APP_NAME"; then
    die "App name must be a lowercase letter, then lowercase letters, digits, or hyphens."
  fi
  if [[ -n "$GIT_URL" ]] && ! valid_git_remote "$GIT_URL"; then
    die "The git repository must be a URL or path with no spaces."
  fi
  if [[ "$MODE" == "production" && -n "$SOURCE" ]]; then
    die "Production does not install Laravel or clone a repository during first install."
  fi
}

ask_missing() {
  if [[ -z "$MODE" ]]; then
    ask_mode || return 1
  fi
  if [[ -z "$APP_NAME" ]]; then
    ask_name || return 1
  fi
  if [[ "$MODE" == "production" && -n "$SOURCE" ]]; then
    die "Production does not install Laravel or clone a repository during first install."
  fi
  if [[ "$MODE" == "development" && -z "$SOURCE" ]]; then
    ask_source || return 1
  fi
}

skip_existing() {
  local names
  names="$(app_names | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  echo "Apps already registered: ${names}"
  echo "First-install questions are skipped."
  echo "Add another app with: ./dock new-app <name> [host]"
}

main() {
  parse_args "$@"
  validate_flags
  if [[ -n "$(app_names)" ]]; then
    skip_existing
    exit 0
  fi
  if [[ "$DRY" -eq 1 ]]; then
    if answers_complete; then
      print_plan 1
    else
      print_questions
    fi
    exit 0
  fi
  if [[ "$NO_INTERACTION" -eq 1 ]]; then
    if ! answers_complete; then
      die "Missing answers for a non-interactive install. Required: --env development|production and --name <app>. Development also needs --laravel or --git <url>. See ./dock help install."
    fi
  else
    ask_missing || exit 1
  fi
  if ! answers_complete; then
    die "Missing answers. See ./dock help install."
  fi
  print_plan 0
  echo
  execute
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
