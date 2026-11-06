#!/usr/bin/env bash
# Create a Meilisearch API key limited to <app>_* indexes.
# Writes the key only to the path given by --out. Never prints it.
# Does not fall back to MEILI_MASTER_KEY.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/_lib.sh
source "$ROOT/scripts/_lib.sh"

OUT=""
APP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      [[ $# -ge 2 ]] || { echo "--out needs a file path" >&2; exit 1; }
      OUT="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: meili-app-key.sh --out <file> <app>"
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      APP="$1"
      shift
      ;;
  esac
done

if [[ -z "$APP" || -z "$OUT" ]]; then
  echo "Usage: meili-app-key.sh --out <file> <app>" >&2
  exit 1
fi
if [[ ! "$APP" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "Refusing Meilisearch key for unsafe app name." >&2
  exit 1
fi

install -m 600 /dev/null "$OUT"

if ! profile_has search; then
  : > "$OUT"
  exit 0
fi

meili_running() {
  "${COMPOSE[@]}" ps meilisearch --status running --format '{{.Name}}' 2>/dev/null | grep -q .
}

if ! meili_running; then
  echo "Starting Meilisearch to issue a per-app API key..."
  "${COMPOSE[@]}" --profile search up -d --wait --no-deps meilisearch
fi

body="$(printf '{"name":"app:%s","description":"Indexes %s_*","actions":["search","documents.*","indexes.*","settings.*","tasks.*"],"indexes":["%s_*"],"expiresAt":null}' "$APP" "$APP" "$APP")"

fetch() {
  local method="$1"
  if [[ "$method" == "POST" ]]; then
    "${COMPOSE[@]}" --profile search exec -T -e MEILI_KEY_BODY="$body" meilisearch \
      /bin/sh -c 'wget -qO- --timeout=20 --header="Authorization: Bearer $MEILI_MASTER_KEY" --header="Content-Type: application/json" --post-data="$MEILI_KEY_BODY" http://127.0.0.1:7700/keys'
  else
    "${COMPOSE[@]}" --profile search exec -T meilisearch \
      /bin/sh -c 'wget -qO- --timeout=20 --header="Authorization: Bearer $MEILI_MASTER_KEY" "http://127.0.0.1:7700/keys?limit=1000"'
  fi
}

parse_key='
import json, sys
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.stderr.write("Meilisearch key API did not return JSON\n")
    sys.exit(1)
want = sys.argv[1]
found = None
if isinstance(data, dict) and "results" in data:
    for item in data.get("results") or []:
        if item.get("name") == want and item.get("key"):
            found = item["key"]
            break
elif isinstance(data, dict) and data.get("key"):
    found = data["key"]
if not found:
    message = ""
    if isinstance(data, dict):
        message = data.get("message") or ""
    if message:
        sys.stderr.write("Meilisearch key request failed: %s\n" % message)
    sys.exit(2)
sys.stdout.write(found)
'

key=""
list_json="$(fetch GET || true)"
if [[ -n "$list_json" ]]; then
  if key="$(printf '%s' "$list_json" | python3 -c "$parse_key" "app:${APP}" 2>/dev/null)"; then
    :
  else
    key=""
  fi
fi

if [[ -z "$key" ]]; then
  create_json="$(fetch POST)"
  if ! key="$(printf '%s' "$create_json" | python3 -c "$parse_key" "app:${APP}")"; then
    echo "Meilisearch did not return a per-app key for ${APP}." >&2
    exit 1
  fi
fi

if [[ -z "$key" || "$key" == *$'\n'* ]]; then
  echo "Meilisearch returned an unusable per-app key for ${APP}." >&2
  exit 1
fi

printf '%s' "$key" > "$OUT"
chmod 600 "$OUT"
echo "Meilisearch key created for ${APP} (indexes ${APP}_*)."
