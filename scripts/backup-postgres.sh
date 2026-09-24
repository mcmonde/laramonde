#!/usr/bin/env bash
# Per-app Postgres backups → local staging, optional DigitalOcean Spaces upload.
#
# Usage:
#   ./dock backup              # all app databases (+ globals)
#   ./dock backup <db-name>    # one database only
#
# Fail-safes:
#   - flock so two backups never run at once
#   - dump each DB separately (+ globals when dumping all)
#   - gzip -t + non-empty size before treating a dump as good
#   - upload with ACL private → .tmp key → finalize → HEAD size check
#   - only delete locals that uploaded successfully; leave failures for retry
#   - local disk is staging only — never keep successful uploads on the server
#   - prune Spaces objects older than BACKUP_S3_RETAIN_DAYS (default 30)
#   - warn + fail when Spaces is not configured (so cron/alerts notice)
#   - alert webhook/email on failure
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/_lib.sh
source "$ROOT/scripts/_lib.sh"

# shellcheck disable=SC1091
set -a
# shellcheck source=/dev/null
[[ -f "$ROOT/.env" ]] && source "$ROOT/.env"
set +a

ONLY_DB="${1:-}"
OUT_DIR="${BACKUP_LOCAL_DIR:-$ROOT/backups/postgres}"
STAMP="$(date +%Y%m%d_%H%M%S)"
LOCK_FILE="${BACKUP_LOCK_FILE:-/tmp/laramonde-postgres-backup.lock}"
AWS_CLI_IMAGE="${BACKUP_AWS_CLI_IMAGE:-amazon/aws-cli:2.22.35}"
RETAIN_DAYS="${BACKUP_S3_RETAIN_DAYS:-30}"
HOST_LABEL="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown-host)"

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

# ---- lock --------------------------------------------------------------------

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "ERROR: another backup is already running (lock: $LOCK_FILE)" >&2
  exit 1
fi

# ---- discover databases ------------------------------------------------------

declare -a DB_NAMES=()

add_db() {
  local name="$1"
  [[ -z "$name" ]] && return 0
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
    echo "WARNING: skipping unsafe database name: $name" >&2
    return 0
  }
  local d
  for d in "${DB_NAMES[@]+"${DB_NAMES[@]}"}"; do
    [[ "$d" == "$name" ]] && return 0
  done
  DB_NAMES+=("$name")
}

for defaults in "$ROOT"/sites/*/defaults.env; do
  [[ -f "$defaults" ]] || continue
  app="$(basename "$(dirname "$defaults")")"
  case "$app" in
    _template|_template_octane) continue ;;
  esac
  add_db "$(env_get DB_DATABASE "$defaults")"
done

if [[ -f "$ROOT/postgres/apps.list" ]]; then
  while read -r _app db _user _pass || [[ -n "${_app:-}" ]]; do
    [[ -z "${_app:-}" || "${_app:0:1}" == "#" ]] && continue
    add_db "${db:-}"
  done < "$ROOT/postgres/apps.list"
fi

if [[ -n "$ONLY_DB" ]]; then
  if [[ ! "$ONLY_DB" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "ERROR: invalid database name: $ONLY_DB" >&2
    exit 1
  fi
  DB_NAMES=("$ONLY_DB")
fi

if [[ ${#DB_NAMES[@]} -eq 0 ]]; then
  echo "WARNING: no app databases found in sites/*/defaults.env or postgres/apps.list" >&2
fi

pg_exec() {
  "${COMPOSE[@]}" exec -T postgres "$@"
}

db_exists() {
  local name="$1"
  local found
  found="$(pg_exec psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -Atqc \
    "SELECT 1 FROM pg_database WHERE datname = '${name}'")"
  [[ "$found" == "1" ]]
}

# ---- alerts ------------------------------------------------------------------

ALERT_LINES=()

note_alert() {
  ALERT_LINES+=("$1")
}

send_alerts() {
  local subject="$1"
  local body="$2"

  if [[ -n "${BACKUP_ALERT_WEBHOOK:-}" ]]; then
    if command -v curl >/dev/null 2>&1; then
      local payload
      # Discord Incoming Webhooks expect {"content": "..."} (max 2000 chars).
      # Slack-style hooks expect {"text": "..."}.
      if [[ "${BACKUP_ALERT_WEBHOOK}" == *discord.com/api/webhooks* \
         || "${BACKUP_ALERT_WEBHOOK}" == *discordapp.com/api/webhooks* \
         || "${BACKUP_ALERT_PROVIDER:-}" == "discord" ]]; then
        payload="$(SUBJECT="$subject" BODY="$body" python3 - <<'PY'
import json, os
subject = os.environ.get("SUBJECT", "")
body = os.environ.get("BODY", "")
text = f"**{subject}**\n```\n{body}\n```".strip()
if len(text) > 1900:
    text = text[:1900] + "\n…(truncated)"
print(json.dumps({"content": text}))
PY
)"
      else
        payload="$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.dumps({"text": sys.stdin.read()}))' 2>/dev/null \
          || printf '{"text":%s}' "$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")"
      fi
      if ! curl -fsS -X POST -H 'Content-Type: application/json' \
        -d "$payload" "${BACKUP_ALERT_WEBHOOK}" >/dev/null; then
        echo "WARNING: BACKUP_ALERT_WEBHOOK POST failed" >&2
      else
        echo "Alert webhook notified."
      fi
    else
      echo "WARNING: curl missing — cannot POST BACKUP_ALERT_WEBHOOK" >&2
    fi
  fi

  if [[ -n "${BACKUP_ALERT_EMAIL:-}" ]]; then
    if command -v mail >/dev/null 2>&1; then
      if printf '%s\n' "$body" | mail -s "$subject" "${BACKUP_ALERT_EMAIL}"; then
        echo "Alert email sent to ${BACKUP_ALERT_EMAIL}."
      else
        echo "WARNING: mail to ${BACKUP_ALERT_EMAIL} failed" >&2
      fi
    else
      echo "WARNING: mail command missing — cannot send BACKUP_ALERT_EMAIL" >&2
    fi
  fi
}

finish_with_status() {
  local code="$1"
  if [[ "$code" -ne 0 ]]; then
    local body
    body="$(printf 'Postgres backup FAILED on %s at %s\n\n%s\n' \
      "$HOST_LABEL" "$(date -Is)" "$(printf '%s\n' "${ALERT_LINES[@]+"${ALERT_LINES[@]}"}")")"
    send_alerts "[laramonde] backup FAILED on ${HOST_LABEL}" "$body"
  fi
  exit "$code"
}

# ---- Spaces config -----------------------------------------------------------

spaces_configured() {
  [[ -n "${BACKUP_S3_BUCKET:-}" \
    && -n "${BACKUP_S3_ACCESS_KEY_ID:-}" \
    && -n "${BACKUP_S3_SECRET_ACCESS_KEY:-}" \
    && -n "${BACKUP_S3_ENDPOINT:-}" ]]
}

remind_spaces() {
  if [[ "${BACKUP_REQUIRE_SPACES:-0}" == "1" ]]; then
    cat >&2 <<'EOF'
ERROR: DigitalOcean Spaces is NOT configured, but BACKUP_REQUIRE_SPACES=1.
  Staging/production expect offsite copies. Set BACKUP_S3_* in the root .env:
    BACKUP_S3_ENDPOINT=https://<region>.digitaloceanspaces.com
    BACKUP_S3_REGION=<region>
    BACKUP_S3_BUCKET=<bucket>
    BACKUP_S3_PREFIX=laramonde/postgres
    BACKUP_S3_ACCESS_KEY_ID=...
    BACKUP_S3_SECRET_ACCESS_KEY=...
    BACKUP_S3_RETAIN_DAYS=30
  Dumps from this run stay under backups/postgres/ for retry after Spaces is set.
EOF
    note_alert "Spaces not configured while BACKUP_REQUIRE_SPACES=1"
  else
    cat >&2 <<'EOF'
INFO: DigitalOcean Spaces is not configured (normal for local/dev).
  Dumps stay under backups/postgres/ on this machine.
  Staging/production: set BACKUP_S3_* and BACKUP_REQUIRE_SPACES=1 so uploads
  are required and server disk is cleared after a successful private upload.
EOF
  fi
}

s3_aws() {
  if command -v aws >/dev/null 2>&1; then
    AWS_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID}" \
    AWS_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY}" \
    AWS_DEFAULT_REGION="${BACKUP_S3_REGION:-us-east-1}" \
      aws --endpoint-url "${BACKUP_S3_ENDPOINT}" "$@"
    return
  fi

  docker run --rm \
    -e AWS_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID}" \
    -e AWS_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY}" \
    -e AWS_DEFAULT_REGION="${BACKUP_S3_REGION:-us-east-1}" \
    -v "${OUT_DIR}:/backup:rw" \
    "${AWS_CLI_IMAGE}" \
    --endpoint-url "${BACKUP_S3_ENDPOINT}" \
    "$@"
}

s3_prefix() {
  local prefix="${BACKUP_S3_PREFIX:-laramonde/postgres}"
  prefix="${prefix#/}"
  prefix="${prefix%/}"
  printf '%s' "$prefix"
}

s3_key_for() {
  local filename="$1"
  local prefix
  prefix="$(s3_prefix)"
  if [[ -n "$prefix" ]]; then
    printf '%s/%s' "$prefix" "$filename"
  else
    printf '%s' "$filename"
  fi
}

# Upload one local file privately; verify remote size; always delete local on success.
# Server disk is staging only — successful uploads must not linger.
upload_one() {
  local local_path="$1"
  local filename base_key tmp_key remote_size local_size upload_src
  filename="$(basename "$local_path")"
  base_key="$(s3_key_for "$filename")"
  tmp_key="${base_key}.tmp.$$"
  local_size="$(wc -c < "$local_path" | tr -d ' ')"

  upload_src="$local_path"
  if ! command -v aws >/dev/null 2>&1; then
    upload_src="/backup/${filename}"
  fi

  echo "  → uploading (private) s3://${BACKUP_S3_BUCKET}/${base_key}"
  if ! s3_aws s3 cp "$upload_src" "s3://${BACKUP_S3_BUCKET}/${tmp_key}" \
    --acl private --only-show-errors; then
    echo "  ERROR: upload failed for $filename (keeping local for retry)" >&2
    note_alert "Upload failed: $filename"
    s3_aws s3 rm "s3://${BACKUP_S3_BUCKET}/${tmp_key}" --only-show-errors 2>/dev/null || true
    return 1
  fi

  if ! s3_aws s3 mv "s3://${BACKUP_S3_BUCKET}/${tmp_key}" "s3://${BACKUP_S3_BUCKET}/${base_key}" \
    --only-show-errors; then
    echo "  ERROR: finalize (mv) failed for $filename (keeping local for retry)" >&2
    note_alert "Finalize failed: $filename"
    s3_aws s3 rm "s3://${BACKUP_S3_BUCKET}/${tmp_key}" --only-show-errors 2>/dev/null || true
    return 1
  fi

  # Ensure final object is private (mv can drop ACL on some S3-compatible stores)
  s3_aws s3api put-object-acl --bucket "${BACKUP_S3_BUCKET}" --key "${base_key}" \
    --acl private >/dev/null 2>&1 || true

  remote_size="$(s3_aws s3api head-object --bucket "${BACKUP_S3_BUCKET}" --key "${base_key}" \
    --query ContentLength --output text 2>/dev/null || true)"
  remote_size="$(printf '%s' "$remote_size" | tr -d '[:space:]')"
  if [[ -z "$remote_size" || "$remote_size" == "None" ]]; then
    echo "  ERROR: could not HEAD remote object for $filename — keeping local for retry" >&2
    note_alert "HEAD failed after upload: $filename"
    return 1
  fi
  if [[ "$remote_size" != "$local_size" ]]; then
    echo "  ERROR: size mismatch for $filename (local=$local_size remote=$remote_size) — keeping local for retry" >&2
    note_alert "Size mismatch: $filename local=$local_size remote=$remote_size"
    return 1
  fi

  rm -f "$local_path"
  echo "  ✓ uploaded private + verified ($local_size bytes); removed local staging copy"
  return 0
}

# Delete Spaces objects under prefix older than RETAIN_DAYS.
prune_remote() {
  local prefix days cutoff_epoch list_json
  prefix="$(s3_prefix)"
  days="$RETAIN_DAYS"
  if ! [[ "$days" =~ ^[0-9]+$ ]] || [[ "$days" -le 0 ]]; then
    echo "Skipping remote prune (BACKUP_S3_RETAIN_DAYS=$days)"
    return 0
  fi

  cutoff_epoch="$(date -u -d "${days} days ago" +%s 2>/dev/null || date -u -v-"${days}"d +%s 2>/dev/null || true)"
  if [[ -z "$cutoff_epoch" ]]; then
    echo "WARNING: could not compute retention cutoff — skip prune" >&2
    return 0
  fi

  echo "Pruning Spaces objects older than ${days} day(s) under prefix '${prefix}'..."

  local list_args=(s3api list-objects-v2 --bucket "${BACKUP_S3_BUCKET}" --output json)
  if [[ -n "$prefix" ]]; then
    list_args+=(--prefix "${prefix}/")
  fi

  if ! list_json="$(s3_aws "${list_args[@]}" 2>/dev/null)"; then
    echo "WARNING: list-objects for prune failed" >&2
    note_alert "Remote prune list failed"
    return 0
  fi

  local key deleted=0
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    echo "  pruned ${key}"
    if s3_aws s3 rm "s3://${BACKUP_S3_BUCKET}/${key}" --only-show-errors; then
      deleted=$((deleted + 1))
    else
      echo "  WARNING: failed to delete ${key}" >&2
      note_alert "Prune delete failed: ${key}"
    fi
  done < <(CUTOFF="$cutoff_epoch" python3 -c '
import json, os, sys
from datetime import datetime
data = json.load(sys.stdin)
cutoff = int(os.environ["CUTOFF"])
for obj in data.get("Contents") or []:
    key = obj.get("Key") or ""
    if not key or key.endswith("/"):
        continue
    lm = obj.get("LastModified") or ""
    # Always drop leftover temp uploads
    if ".tmp." in key:
        print(key)
        continue
    try:
        ts = datetime.fromisoformat(lm.replace("Z", "+00:00")).timestamp()
    except Exception:
        continue
    if ts < cutoff:
        print(key)
' <<<"$list_json")

  echo "Prune complete (${deleted} object(s) removed)."
}

# ---- dump --------------------------------------------------------------------

declare -a CREATED_FILES=()
DUMP_ERRORS=0

verify_dump() {
  local path="$1"
  if [[ ! -s "$path" ]]; then
    echo "ERROR: dump empty or missing: $path" >&2
    return 1
  fi
  if ! gzip -t "$path" 2>/dev/null; then
    echo "ERROR: gzip integrity check failed: $path" >&2
    return 1
  fi
  return 0
}

echo "=== Postgres backup ${STAMP} ==="
echo "Host: $HOST_LABEL"
echo "Local staging: $OUT_DIR"
if [[ -n "$ONLY_DB" ]]; then
  echo "Mode: single database ($ONLY_DB)"
else
  echo "Mode: all app databases + globals"
fi

# Globals only when dumping everything (not useful alone for a single-DB rollback)
if [[ -z "$ONLY_DB" ]]; then
  GLOBALS_FILE="$OUT_DIR/globals_${STAMP}.sql.gz"
  echo "Dumping globals → $(basename "$GLOBALS_FILE")"
  if pg_exec pg_dumpall -U "${POSTGRES_USER:-postgres}" --globals-only | gzip -c > "$GLOBALS_FILE" \
    && verify_dump "$GLOBALS_FILE"; then
    chmod 600 "$GLOBALS_FILE"
    CREATED_FILES+=("$GLOBALS_FILE")
  else
    rm -f "$GLOBALS_FILE"
    echo "ERROR: globals dump failed" >&2
    note_alert "Globals dump failed"
    DUMP_ERRORS=$((DUMP_ERRORS + 1))
  fi
fi

for db in "${DB_NAMES[@]+"${DB_NAMES[@]}"}"; do
  if ! db_exists "$db"; then
    echo "ERROR: database '$db' not present in Postgres" >&2
    note_alert "Database missing: $db"
    DUMP_ERRORS=$((DUMP_ERRORS + 1))
    continue
  fi
  out="$OUT_DIR/${db}_${STAMP}.sql.gz"
  echo "Dumping database '$db' → $(basename "$out")"
  if pg_exec pg_dump -U "${POSTGRES_USER:-postgres}" -d "$db" --format=plain --no-password \
    | gzip -c > "$out" \
    && verify_dump "$out"; then
    chmod 600 "$out"
    CREATED_FILES+=("$out")
  else
    rm -f "$out"
    echo "ERROR: dump failed for database '$db'" >&2
    note_alert "Dump failed: $db"
    DUMP_ERRORS=$((DUMP_ERRORS + 1))
  fi
done

if [[ ${#CREATED_FILES[@]} -eq 0 ]]; then
  echo "ERROR: no successful dumps produced" >&2
  note_alert "No successful dumps produced"
  finish_with_status 1
fi

echo "Created ${#CREATED_FILES[@]} dump file(s) (${DUMP_ERRORS} dump error(s))"
echo "Policy: server keeps dumps only until Spaces upload succeeds; next cron/manual run retries leftovers."

# ---- upload or remind --------------------------------------------------------

UPLOAD_FAILS=0
UPLOAD_OK=0
SPACES_MISSING=0

if spaces_configured; then
  echo "Spaces: bucket=${BACKUP_S3_BUCKET} prefix=$(s3_prefix) endpoint=${BACKUP_S3_ENDPOINT} acl=private retain_days=${RETAIN_DAYS}"

  declare -a TO_UPLOAD=()
  while IFS= read -r -d '' f; do
    TO_UPLOAD+=("$f")
  done < <(find "$OUT_DIR" -maxdepth 1 -type f -name '*.sql.gz' -print0 | sort -z)

  if [[ ${#TO_UPLOAD[@]} -gt ${#CREATED_FILES[@]} ]]; then
    echo "Also retrying $(( ${#TO_UPLOAD[@]} - ${#CREATED_FILES[@]} )) leftover staging file(s) from earlier failed uploads."
  fi

  for f in "${TO_UPLOAD[@]+"${TO_UPLOAD[@]}"}"; do
    if upload_one "$f"; then
      UPLOAD_OK=$((UPLOAD_OK + 1))
    else
      UPLOAD_FAILS=$((UPLOAD_FAILS + 1))
    fi
  done

  echo "Upload summary: ${UPLOAD_OK} ok, ${UPLOAD_FAILS} failed (failed files kept locally for next run)"
  prune_remote
else
  SPACES_MISSING=1
  remind_spaces
  echo "Local dumps retained:"
  for f in "${CREATED_FILES[@]}"; do
    echo "  - $f"
  done
fi

# Report staging leftovers (meaningful when Spaces is in use)
REMAINING=0
while IFS= read -r -d '' _; do
  REMAINING=$((REMAINING + 1))
done < <(find "$OUT_DIR" -maxdepth 1 -type f -name '*.sql.gz' -print0 2>/dev/null || true)

if spaces_configured; then
  if [[ "$REMAINING" -eq 0 ]]; then
    echo "Server staging clear — no backup files left on disk."
  else
    echo "WARNING: ${REMAINING} staging file(s) still on server (upload failed):"
    find "$OUT_DIR" -maxdepth 1 -type f -name '*.sql.gz' -printf '  - %f (%k KB)\n' 2>/dev/null \
      || find "$OUT_DIR" -maxdepth 1 -type f -name '*.sql.gz' -exec ls -la {} \;
    note_alert "${REMAINING} staging file(s) remain on server"
  fi
else
  echo "Local/dev mode: ${REMAINING} dump file(s) on disk under ${OUT_DIR}"
fi

# Spaces missing is only a hard failure when required (staging/prod)
SPACES_REQUIRED_FAIL=0
if [[ "$SPACES_MISSING" -eq 1 && "${BACKUP_REQUIRE_SPACES:-0}" == "1" ]]; then
  SPACES_REQUIRED_FAIL=1
fi

if [[ "$DUMP_ERRORS" -gt 0 || "$UPLOAD_FAILS" -gt 0 || "$SPACES_REQUIRED_FAIL" -eq 1 ]]; then
  finish_with_status 1
fi

echo "Backup complete."
finish_with_status 0
