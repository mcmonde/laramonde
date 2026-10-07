#!/usr/bin/env bash
# Inspect a Laravel repo before ./dock new-app: PHP version, runtime, layout,
# missing PHP extensions / system packages, unused heavy dependencies.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: scan-app.sh <repo-url|path> [--branch NAME] [--php X.Y] [--no-docker]

  <repo-url|path>  git URL (cloned shallow to a temp dir) or a local checkout
  --branch NAME    branch to scan (git URLs only; default: repo default branch)
  --php X.Y        check against this PHP version instead of the suggested one
  --no-docker      static scan only (no composer check inside the shared image)

Examples:
  ./dock scan-app git@bitbucket.org:team/api.git --branch dev
  ./dock scan-app apps/hcdcresearch
EOF
}

TARGET=""
BRANCH=""
PY_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) [[ $# -ge 2 ]] || { echo "--branch needs a name"; exit 1; }; BRANCH="$2"; shift 2 ;;
    --branch=*) BRANCH="${1#--branch=}"; shift ;;
    --php) [[ $# -ge 2 ]] || { echo "--php needs a version"; exit 1; }; PY_ARGS+=(--php "$2"); shift 2 ;;
    --php=*) PY_ARGS+=(--php "${1#--php=}"); shift ;;
    --no-docker) PY_ARGS+=(--no-docker); shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1"; usage; exit 1 ;;
    *)
      if [[ -z "$TARGET" ]]; then TARGET="$1"; else echo "Unexpected: $1"; usage; exit 1; fi
      shift
      ;;
  esac
done

[[ -n "$TARGET" ]] || { usage; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required for scan-app"; exit 1; }

SRC=""
TMP=""
cleanup() { [[ -n "$TMP" ]] && rm -rf "$TMP"; }
trap cleanup EXIT

if [[ -d "$TARGET" ]]; then
  SRC="$(cd "$TARGET" && pwd)"
  [[ -z "$BRANCH" ]] || echo "Note: --branch is ignored for local paths (scanning the working tree)."
elif [[ "$TARGET" == *"://"* || "$TARGET" =~ ^[^/[:space:]]+@[^:[:space:]]+: ]]; then
  TMP="$(mktemp -d)"
  clone=(git clone --quiet --depth 1)
  [[ -n "$BRANCH" ]] && clone+=(--branch "$BRANCH")
  echo "Cloning ${TARGET}${BRANCH:+ (branch $BRANCH)}…"
  GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3}" \
    timeout 180 "${clone[@]}" "$TARGET" "$TMP/src"
  SRC="$TMP/src"
else
  echo "Not a directory or git URL: $TARGET"
  exit 1
fi

DEFAULT_PHP="8.4"
if [[ -f "$ROOT/.env" ]]; then
  v="$({ grep -E '^PHP_VERSION=' "$ROOT/.env" || true; } | head -n1 | cut -d= -f2-)"
  DEFAULT_PHP="${v:-$DEFAULT_PHP}"
fi
PHP_IMAGE="multiapp-php"
OCTANE_IMAGE="multiapp-php-octane"
if [[ -f "$ROOT/.env" ]]; then
  v="$({ grep -E '^PHP_IMAGE=' "$ROOT/.env" || true; } | head -n1 | cut -d= -f2-)"; PHP_IMAGE="${v:-$PHP_IMAGE}"
  v="$({ grep -E '^PHP_OCTANE_IMAGE=' "$ROOT/.env" || true; } | head -n1 | cut -d= -f2-)"; OCTANE_IMAGE="${v:-$OCTANE_IMAGE}"
fi

python3 "$ROOT/scripts/scan_app.py" "$SRC" \
  --root "$ROOT" \
  --label "$TARGET${BRANCH:+@$BRANCH}" \
  --default-php "$DEFAULT_PHP" \
  --php-image "$PHP_IMAGE" \
  --octane-image "$OCTANE_IMAGE" \
  "${PY_ARGS[@]}"
