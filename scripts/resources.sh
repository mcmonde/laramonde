#!/usr/bin/env bash
# Detect host CPU/RAM and allocate stack + per-app limits.
# Subcommands: detect | plan | check | apply | status
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/_lib.sh
source "$ROOT/scripts/_lib.sh"

ENV_FILE="$ROOT/.env"
PLAN_FILE="$ROOT/.resources.plan"

# auto (default) = cgroup CPU/RAM limits from host plan
# unlimited     = no Docker limits (cpus/memory 0 → compose clears limits);
#                 capacity hard-blocks become warnings only
resource_mode() {
  local m
  m="$(env_get RESOURCE_MODE "$ENV_FILE")"
  m="$(echo "${m:-auto}" | tr '[:upper:]' '[:lower:]')"
  case "$m" in
    unlimited|none|off|0) echo "unlimited" ;;
    *) echo "auto" ;;
  esac
}

resource_mode_unlimited() {
  [[ "$(resource_mode)" == "unlimited" ]]
}

# ---- host detection --------------------------------------------------------

host_cpus() {
  if [[ -n "${HOST_CPUS_OVERRIDE:-}" ]]; then
    echo "$HOST_CPUS_OVERRIDE"
    return
  fi
  nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1
}

host_mem_mb() {
  if [[ -n "${HOST_MEM_MB_OVERRIDE:-}" ]]; then
    echo "$HOST_MEM_MB_OVERRIDE"
    return
  fi
  if [[ -r /proc/meminfo ]]; then
    awk '/MemTotal:/ { printf "%d\n", $2/1024 }' /proc/meminfo
    return
  fi
  # fallback (macOS etc.)
  if command -v sysctl >/dev/null 2>&1; then
    local bytes
    bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
    echo $((bytes / 1024 / 1024))
    return
  fi
  echo 2048
}

# ---- app inventory ---------------------------------------------------------

list_apps() {
  local d app
  shopt -s nullglob
  for d in "$ROOT"/sites/*/defaults.env; do
    app="$(basename "$(dirname "$d")")"
    case "$app" in
      _*) continue ;;
    esac
    echo "$app"
  done
  shopt -u nullglob
}

app_count() {
  list_apps | wc -l | tr -d ' '
}

# ---- units -----------------------------------------------------------------

# float multiply: awk
fmul() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", a*b}'; }
fadd() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", a+b}'; }
fdiv() { awk -v a="$1" -v b="$2" 'BEGIN{ if(b==0){print 0}else{printf "%.2f", a/b} }'; }
fmin() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", (a<b?a:b)}'; }
fmax() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", (a>b?a:b)}'; }
imin() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%d", (a<b?a:b)}'; }
imax() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%d", (a>b?a:b)}'; }

mb_to_compose() {
  local mb="$1"
  if [[ "$mb" -ge 1024 ]]; then
    awk -v m="$mb" 'BEGIN{printf "%.1fG", m/1024}' | sed 's/\.0G/G/'
  else
    echo "${mb}M"
  fi
}

# Postgres -c shared_buffers / effective_cache_size need MB|GB (not Docker's M|G).
mb_to_postgres() {
  local mb="$1"
  if [[ "$mb" -ge 1024 ]]; then
    awk -v m="$mb" 'BEGIN{printf "%.1fGB", m/1024}' | sed 's/\.0GB/GB/'
  else
    echo "${mb}MB"
  fi
}

# ---- planning --------------------------------------------------------------

# Globals set by build_plan:
# PLAN_OK, PLAN_REASON, HOST_CPUS, HOST_MEM_MB, APP_N, EXTRA_N, EXTRA_OCTANE
# INFRA_* and APP_* allocations

build_plan() {
  local extra_apps="${1:-0}"
  local extra_octane="${2:-0}"  # how many of the extras are octane (0 or 1 typically)

  HOST_CPUS="$(host_cpus)"
  HOST_MEM_MB="$(host_mem_mb)"

  local existing existing_octane=0
  existing="$(app_count)"
  local app
  for app in $(list_apps); do
    if [[ "$(app_runtime "$app")" == "octane" ]]; then
      existing_octane=$((existing_octane + 1))
    fi
  done

  APP_N=$((existing + extra_apps))
  local octane_n=$((existing_octane + extra_octane))
  local fpm_n=$((APP_N - octane_n))
  if [[ "$fpm_n" -lt 0 ]]; then fpm_n=0; fi

  # OS reserve: 20% of RAM, floor 512MB, ceil 2048MB on small/medium
  local os_mb
  os_mb="$(imax 512 "$(imin 2048 "$((HOST_MEM_MB * 20 / 100))")")"
  local os_cpu="0.25"
  if awk -v c="$HOST_CPUS" 'BEGIN{exit !(c>=4)}'; then
    os_cpu="0.50"
  fi

  # Infra (always)
  local nginx_mb=64 nginx_cpu="0.25"
  local pg_mb redis_mb meili_mb=0 ws_mb=0 mail_mb=0 cert_mb=0
  local pg_cpu="0.50" redis_cpu="0.25" meili_cpu="0" ws_cpu="0" mail_cpu="0" cert_cpu="0"

  # Postgres ~12% of host, clamp 256–4096
  pg_mb="$(imax 256 "$(imin 4096 "$((HOST_MEM_MB * 12 / 100))")")"
  # Redis ~3%, clamp 64–1024
  redis_mb="$(imax 64 "$(imin 1024 "$((HOST_MEM_MB * 3 / 100))")")"

  if profile_has search; then
    meili_mb="$(imax 128 "$(imin 2048 "$((HOST_MEM_MB * 5 / 100))")")"
    meili_cpu="0.25"
  fi
  if profile_has dev; then
    ws_mb=256
    ws_cpu="0.25"
  fi
  if profile_has dev || profile_has mail; then
    mail_mb=64
    mail_cpu="0.10"
  fi
  if profile_has tls; then
    cert_mb=64
    cert_cpu="0.10"
  fi

  # Scale infra CPU with host
  if awk -v c="$HOST_CPUS" 'BEGIN{exit !(c>=4)}'; then
    pg_cpu="1.00"
    redis_cpu="0.50"
    nginx_cpu="0.50"
  fi
  if awk -v c="$HOST_CPUS" 'BEGIN{exit !(c>=8)}'; then
    pg_cpu="2.00"
    redis_cpu="1.00"
  fi

  local infra_mb infra_cpu
  infra_mb=$((nginx_mb + pg_mb + redis_mb + meili_mb + ws_mb + mail_mb + cert_mb))
  infra_cpu="$(fadd "$nginx_cpu" "$(fadd "$pg_cpu" "$(fadd "$redis_cpu" "$(fadd "$meili_cpu" "$(fadd "$ws_cpu" "$(fadd "$mail_cpu" "$cert_cpu")")")")")")"

  # Per-app minimums (exported for capacity math)
  FPM_MIN_MB=288
  FPM_MIN_CPU="0.50"
  OCT_MIN_MB=352
  OCT_MIN_CPU="0.60"
  local fpm_min_mb=$FPM_MIN_MB fpm_min_cpu=$FPM_MIN_CPU
  local oct_min_mb=$OCT_MIN_MB oct_min_cpu=$OCT_MIN_CPU
  local apps_min_mb apps_min_cpu
  apps_min_mb=$((fpm_n * fpm_min_mb + octane_n * oct_min_mb))
  apps_min_cpu="$(fadd "$(fmul "$fpm_n" "$fpm_min_cpu")" "$(fmul "$octane_n" "$oct_min_cpu")")"

  local avail_mb avail_cpu
  avail_mb=$((HOST_MEM_MB - os_mb - infra_mb))
  if [[ "$avail_mb" -lt 0 ]]; then avail_mb=0; fi
  avail_cpu="$(awk -v h="$HOST_CPUS" -v o="$os_cpu" -v i="$infra_cpu" 'BEGIN{v=h-o-i; if(v<0)v=0; printf "%.2f", v}')"

  PLAN_OK=1
  PLAN_LEVEL="ok"   # ok | warn | critical | blocked
  PLAN_REASON=""
  if [[ "$APP_N" -le 0 ]]; then
    PLAN_REASON="No apps to allocate yet (infra-only plan)."
  fi
  if [[ "$avail_mb" -lt "$apps_min_mb" ]]; then
    PLAN_OK=0
    PLAN_LEVEL="blocked"
    PLAN_REASON="Not enough RAM: need ≥${apps_min_mb}MB for ${APP_N} app(s) after OS(${os_mb}MB)+infra(${infra_mb}MB); only ${avail_mb}MB left (host ${HOST_MEM_MB}MB)."
  fi
  if awk -v a="$avail_cpu" -v m="$apps_min_cpu" 'BEGIN{exit !(a+0 < m+0)}'; then
    PLAN_OK=0
    PLAN_LEVEL="blocked"
    local why="Not enough CPU: need ≥${apps_min_cpu} cores for ${APP_N} app(s) after OS+infra; only ${avail_cpu} left (host ${HOST_CPUS})."
    if [[ -n "$PLAN_REASON" && "$PLAN_REASON" != "No apps to allocate yet (infra-only plan)." ]]; then
      PLAN_REASON="$PLAN_REASON $why"
    else
      PLAN_REASON="$why"
    fi
  fi

  # Soft → critical warnings by RAM/CPU fill of the app budget
  PLAN_WARN=""
  local used_pct_ram=0 used_pct_cpu=0
  if [[ "$avail_mb" -gt 0 && "$apps_min_mb" -gt 0 ]]; then
    used_pct_ram=$((apps_min_mb * 100 / avail_mb))
  fi
  used_pct_cpu="$(awk -v a="$apps_min_cpu" -v t="$avail_cpu" 'BEGIN{ if(t+0<=0){print 100}else{printf "%d", (a*100)/t} }')"
  PLAN_USED_PCT_RAM=$used_pct_ram
  PLAN_USED_PCT_CPU=$used_pct_cpu

  if [[ "$PLAN_OK" -eq 1 ]]; then
    local worst=$used_pct_ram
    if [[ "$used_pct_cpu" -gt "$worst" ]]; then worst=$used_pct_cpu; fi
    if [[ "$worst" -ge 95 ]]; then
      PLAN_LEVEL="critical"
      PLAN_WARN="CRITICAL: app budget ~${worst}% used (RAM ${used_pct_ram}%, CPU ${used_pct_cpu}%). Host is at its practical limit."
    elif [[ "$worst" -ge 75 ]]; then
      PLAN_LEVEL="warn"
      PLAN_WARN="WARNING: app budget ~${worst}% used (RAM ${used_pct_ram}%, CPU ${used_pct_cpu}%). Few or no more apps will fit."
    fi
  fi

  # Unlimited mode: never hard-block; keep advisory warnings
  if resource_mode_unlimited; then
    if [[ "$PLAN_OK" -eq 0 ]]; then
      local blocked_reason="$PLAN_REASON"
      PLAN_OK=1
      PLAN_LEVEL="warn"
      PLAN_WARN="RESOURCE_MODE=unlimited — hard capacity block bypassed (${blocked_reason}). Kernel OOM may kill processes under pressure."
      PLAN_REASON="Unlimited mode: Docker CPU/RAM limits will not be applied."
    elif [[ -z "${PLAN_WARN:-}" ]]; then
      PLAN_WARN="RESOURCE_MODE=unlimited — Docker CPU/RAM cgroup limits disabled; host OOM killer is the safety net."
    else
      PLAN_WARN="${PLAN_WARN} (RESOURCE_MODE=unlimited — no cgroup caps)"
    fi
  fi

  # Distribute surplus by per-app RESOURCE_WEIGHT (default 1).
  # Octane gets an automatic 1.25× multiplier on top of that weight.
  local weight_total="0"
  local app w
  for app in $(list_apps); do
    w="$(app_effective_weight "$app")"
    weight_total="$(fadd "$weight_total" "$w")"
  done
  # extras not yet on disk (preflight for new-app)
  if [[ "$extra_apps" -gt 0 ]]; then
    local ew="1"
    if [[ "$extra_octane" -gt 0 ]]; then
      ew="$(awk -v n="$extra_octane" 'BEGIN{printf "%.2f", n*1.25}')"
      local fpm_extra=$((extra_apps - extra_octane))
      if [[ "$fpm_extra" -gt 0 ]]; then
        ew="$(fadd "$ew" "$fpm_extra")"
      fi
    else
      ew="$extra_apps"
    fi
    weight_total="$(fadd "$weight_total" "$ew")"
  fi

  SURPLUS_MB=0
  SURPLUS_CPU="0"
  WEIGHT_TOTAL="$weight_total"
  if [[ "$PLAN_OK" -eq 1 && "$APP_N" -gt 0 ]]; then
    SURPLUS_MB=$((avail_mb - apps_min_mb))
    if [[ "$SURPLUS_MB" -lt 0 ]]; then SURPLUS_MB=0; fi
    SURPLUS_CPU="$(awk -v a="$avail_cpu" -v m="$apps_min_cpu" 'BEGIN{printf "%.2f", (a>m?a-m:0)}')"
  fi

  # Reference “weight=1 FPM” and “weight=1 Octane” shares for display
  local unit_mb=0 unit_cpu="0"
  if awk -v w="$weight_total" 'BEGIN{exit !(w>0)}'; then
    unit_mb="$(awk -v s="$SURPLUS_MB" -v w="$weight_total" 'BEGIN{printf "%d", s/w}')"
    unit_cpu="$(awk -v s="$SURPLUS_CPU" -v w="$weight_total" 'BEGIN{printf "%.2f", s/w}')"
  fi
  FPM_TOTAL_MB=$((fpm_min_mb + unit_mb))
  FPM_TOTAL_CPU="$(fadd "$fpm_min_cpu" "$unit_cpu")"
  OCT_TOTAL_MB="$(awk -v m="$oct_min_mb" -v u="$unit_mb" 'BEGIN{printf "%d", m + u*1.25}')"
  OCT_TOTAL_CPU="$(awk -v m="$oct_min_cpu" -v u="$unit_cpu" 'BEGIN{printf "%.2f", m + u*1.25}')"

  FPM_TOTAL_MB="$(imin "$FPM_TOTAL_MB" 4096)"
  OCT_TOTAL_MB="$(imin "$OCT_TOTAL_MB" 6144)"
  FPM_TOTAL_CPU="$(fmin "$FPM_TOTAL_CPU" 4.00)"
  OCT_TOTAL_CPU="$(fmin "$OCT_TOTAL_CPU" 6.00)"

  # Store infra for apply
  INFRA_NGINX_MB=$nginx_mb INFRA_NGINX_CPU=$nginx_cpu
  INFRA_PG_MB=$pg_mb INFRA_PG_CPU=$pg_cpu
  INFRA_REDIS_MB=$redis_mb INFRA_REDIS_CPU=$redis_cpu
  INFRA_MEILI_MB=$meili_mb INFRA_MEILI_CPU=$meili_cpu
  INFRA_WS_MB=$ws_mb INFRA_WS_CPU=$ws_cpu
  INFRA_MAIL_MB=$mail_mb INFRA_MAIL_CPU=$mail_cpu
  INFRA_CERT_MB=$cert_mb INFRA_CERT_CPU=$cert_cpu
  INFRA_TOTAL_MB=$infra_mb
  OS_MB=$os_mb
  PLAN_EXISTING=$existing
  PLAN_EXTRA=$extra_apps
  PLAN_OCTANE_N=$octane_n
  PLAN_FPM_N=$fpm_n
  PLAN_AVAIL_MB=$avail_mb
  PLAN_APPS_MIN_MB=$apps_min_mb
  PLAN_AVAIL_CPU=$avail_cpu
  PLAN_APPS_MIN_CPU=$apps_min_cpu
}

# Split one app's budget across containers (percentages)
split_app_budget() {
  local total_mb="$1" total_cpu="$2" kind="$3"
  if [[ "$kind" == "octane" ]]; then
    HTTP_MB="$(awk -v t="$total_mb" 'BEGIN{printf "%d", t*0.50}')"
    QUEUE_MB="$(awk -v t="$total_mb" 'BEGIN{printf "%d", t*0.25}')"
    REVERB_MB="$(awk -v t="$total_mb" 'BEGIN{printf "%d", t*0.18}')"
    SCHED_MB="$(awk -v t="$total_mb" 'BEGIN{printf "%d", t*0.07}')"
    HTTP_CPU="$(awk -v t="$total_cpu" 'BEGIN{printf "%.2f", t*0.50}')"
    QUEUE_CPU="$(awk -v t="$total_cpu" 'BEGIN{printf "%.2f", t*0.25}')"
    REVERB_CPU="$(awk -v t="$total_cpu" 'BEGIN{printf "%.2f", t*0.18}')"
    SCHED_CPU="$(awk -v t="$total_cpu" 'BEGIN{printf "%.2f", t*0.07}')"
  else
    HTTP_MB="$(awk -v t="$total_mb" 'BEGIN{printf "%d", t*0.45}')"
    QUEUE_MB="$(awk -v t="$total_mb" 'BEGIN{printf "%d", t*0.25}')"
    REVERB_MB="$(awk -v t="$total_mb" 'BEGIN{printf "%d", t*0.20}')"
    SCHED_MB="$(awk -v t="$total_mb" 'BEGIN{printf "%d", t*0.10}')"
    HTTP_CPU="$(awk -v t="$total_cpu" 'BEGIN{printf "%.2f", t*0.45}')"
    QUEUE_CPU="$(awk -v t="$total_cpu" 'BEGIN{printf "%.2f", t*0.25}')"
    REVERB_CPU="$(awk -v t="$total_cpu" 'BEGIN{printf "%.2f", t*0.20}')"
    SCHED_CPU="$(awk -v t="$total_cpu" 'BEGIN{printf "%.2f", t*0.10}')"
  fi
  HTTP_MB="$(imax "$HTTP_MB" 128)"
  QUEUE_MB="$(imax "$QUEUE_MB" 64)"
  REVERB_MB="$(imax "$REVERB_MB" 64)"
  SCHED_MB="$(imax "$SCHED_MB" 32)"
}

print_plan() {
  local profiles mode
  profiles="$(profiles_csv)"
  mode="$(resource_mode)"
  echo "════════════════════════════════════════════════════════"
  echo " Host detection"
  echo "════════════════════════════════════════════════════════"
  echo "  CPU : ${HOST_CPUS} core(s)"
  echo "  RAM : ${HOST_MEM_MB} MB ($(mb_to_compose "$HOST_MEM_MB"))"
  echo "  Profiles: ${profiles:-none}"
  echo "  RESOURCE_MODE: ${mode}"
  echo
  compute_capacity
  echo "════════════════════════════════════════════════════════"
  echo " Capacity (minimums: FPM ${FPM_MIN_MB}MB/${FPM_MIN_CPU}cpu, Octane ${OCT_MIN_MB}MB/${OCT_MIN_CPU}cpu)"
  echo "════════════════════════════════════════════════════════"
  if [[ "$mode" == "unlimited" ]]; then
    echo "  Max PHP-FPM / Octane apps    : (unlimited — no cgroup caps; advisory only)"
  else
    echo "  Max PHP-FPM apps on this host : ${CAP_MAX_FPM}"
    echo "  Max Octane apps on this host  : ${CAP_MAX_OCTANE}"
  fi
  echo "  Apps deployed now             : ${PLAN_EXISTING} (rooms left ≈ FPM:${CAP_LEFT_FPM} / Octane:${CAP_LEFT_OCTANE} weight-units)"
  echo
  echo "════════════════════════════════════════════════════════"
  echo " Plan for ${APP_N} app(s) (existing ${PLAN_EXISTING} + new ${PLAN_EXTRA}; fpm=${PLAN_FPM_N} octane=${PLAN_OCTANE_N})"
  echo "════════════════════════════════════════════════════════"
  echo "  OS reserve     : ${OS_MB}MB"
  echo "  Shared infra   : ${INFRA_TOTAL_MB}MB"
  echo "  Left for apps  : ${PLAN_AVAIL_MB}MB / ${PLAN_AVAIL_CPU} CPU"
  echo "  Apps need (min): ${PLAN_APPS_MIN_MB}MB / ${PLAN_APPS_MIN_CPU} CPU"
  echo "  Budget used    : RAM ${PLAN_USED_PCT_RAM:-0}% | CPU ${PLAN_USED_PCT_CPU:-0}%"
  case "${PLAN_LEVEL:-ok}" in
    ok)       echo "  Status         : OK" ;;
    warn)     echo "  Status         : WARNING — nearing limits" ;;
    critical) echo "  Status         : CRITICAL — at practical limit" ;;
    blocked)  echo "  Status         : BLOCKED — over hard limits" ;;
  esac
  if [[ "$mode" == "unlimited" ]]; then
    echo "  Docker limits  : OFF (cpus/memory 0 → no cgroup caps)"
  fi
  if [[ "$PLAN_OK" -eq 1 ]]; then
    if [[ "$mode" != "unlimited" ]]; then
      echo "  Per-app share  : ~$(mb_to_compose "$FPM_TOTAL_MB") FPM (weight=1) | ~$(mb_to_compose "$OCT_TOTAL_MB") Octane (weight=1)"
      echo "  Tip            : set RESOURCE_WEIGHT=2 in sites/<app>/defaults.env for a heavier app"
    else
      echo "  Tip            : set RESOURCE_MODE=auto and ./dock resources apply to restore caps"
    fi
  else
    echo "  Reason         : $PLAN_REASON"
  fi
  if [[ -n "${PLAN_WARN:-}" ]]; then
    echo
    echo "  !! $PLAN_WARN"
  fi
  if [[ "$PLAN_LEVEL" == "blocked" || "$PLAN_LEVEL" == "critical" || "$PLAN_LEVEL" == "warn" ]]; then
    echo
    echo "  Limits reminder:"
    echo "    • Hard stop when min RAM/CPU for all apps exceeds host after OS+infra"
    echo "    • Warn ≥75% of app budget   • Critical ≥95%"
    echo "    • Reduce apps, disable profiles (dev/search), or use a larger host"
  fi
  echo
  echo "Infra allocation:"
  printf '  %-12s %6s  %s\n' "nginx" "$(mb_to_compose "$INFRA_NGINX_MB")" "${INFRA_NGINX_CPU} cpu"
  printf '  %-12s %6s  %s\n' "postgres" "$(mb_to_compose "$INFRA_PG_MB")" "${INFRA_PG_CPU} cpu"
  printf '  %-12s %6s  %s\n' "redis" "$(mb_to_compose "$INFRA_REDIS_MB")" "${INFRA_REDIS_CPU} cpu"
  if [[ "$INFRA_MEILI_MB" -gt 0 ]]; then
    printf '  %-12s %6s  %s\n' "meilisearch" "$(mb_to_compose "$INFRA_MEILI_MB")" "${INFRA_MEILI_CPU} cpu"
  fi
  if [[ "$INFRA_WS_MB" -gt 0 ]]; then
    printf '  %-12s %6s  %s\n' "workspace" "$(mb_to_compose "$INFRA_WS_MB")" "${INFRA_WS_CPU} cpu"
  fi
  if [[ "$INFRA_MAIL_MB" -gt 0 ]]; then
    printf '  %-12s %6s  %s\n' "mailpit" "$(mb_to_compose "$INFRA_MAIL_MB")" "${INFRA_MAIL_CPU} cpu"
  fi
}

# Requires build_plan to have run (sets avail + mins via a zero-extra plan side effect).
# Max apps by hard mins; rooms-left subtracts existing *effective weights* (not raw count).
compute_capacity() {
  FPM_MIN_MB="${FPM_MIN_MB:-288}"
  FPM_MIN_CPU="${FPM_MIN_CPU:-0.50}"
  OCT_MIN_MB="${OCT_MIN_MB:-352}"
  OCT_MIN_CPU="${OCT_MIN_CPU:-0.60}"

  local avail_mb="${PLAN_AVAIL_MB:-0}"
  local avail_cpu="${PLAN_AVAIL_CPU:-0}"

  CAP_MAX_FPM="$(awk -v m="$avail_mb" -v mm="$FPM_MIN_MB" -v c="$avail_cpu" -v cm="$FPM_MIN_CPU" \
    'BEGIN{ a=int(m/mm); b=int(c/cm); if(a<b)print a; else print b; }')"
  CAP_MAX_OCTANE="$(awk -v m="$avail_mb" -v mm="$OCT_MIN_MB" -v c="$avail_cpu" -v cm="$OCT_MIN_CPU" \
    'BEGIN{ a=int(m/mm); b=int(c/cm); if(a<b)print a; else print b; }')"
  if [[ "$CAP_MAX_FPM" -lt 0 ]]; then CAP_MAX_FPM=0; fi
  if [[ "$CAP_MAX_OCTANE" -lt 0 ]]; then CAP_MAX_OCTANE=0; fi

  local used_weight="0" app
  for app in $(list_apps); do
    used_weight="$(fadd "$used_weight" "$(app_effective_weight "$app")")"
  done
  # Rooms left ≈ remaining weight=1 FPM/Octane slots after weighted apps
  CAP_LEFT_FPM="$(awk -v m="$CAP_MAX_FPM" -v u="$used_weight" 'BEGIN{ v=int(m-u); if(v<0)v=0; print v }')"
  CAP_LEFT_OCTANE="$(awk -v m="$CAP_MAX_OCTANE" -v u="$used_weight" 'BEGIN{ v=int(m-u); if(v<0)v=0; print v }')"
}

# Compose prefers project .env over include env_file (sites/*/defaults.env).
# Per-app PHP_/OCTANE_/QUEUE_/… keys must not live in root .env or they shadow
# every app (and break RESOURCE_MODE=unlimited). Strip them on apply.
clear_root_app_limit_overrides() {
  local key
  for key in \
    PHP_CPUS PHP_MEMORY PHP_MEMORY_LIMIT PHP_MAX_CHILDREN \
    OCTANE_CPUS OCTANE_MEMORY OCTANE_COMMAND \
    QUEUE_CPUS QUEUE_MEMORY \
    REVERB_CPUS REVERB_MEMORY \
    SCHEDULER_CPUS SCHEDULER_MEMORY
  do
    env_unset "$key" "$ENV_FILE"
  done
}

apply_infra_to_env() {
  [[ -f "$ENV_FILE" ]] || { echo "Missing .env — run ./dock setup"; exit 1; }

  local unlimited=0
  if resource_mode_unlimited; then unlimited=1; fi

  if [[ "$unlimited" -eq 1 ]]; then
    # cpus/memory 0 → Compose clears deploy.resources.limits (no cgroup caps)
    env_set NGINX_CPUS 0 "$ENV_FILE"
    env_set NGINX_MEMORY 0 "$ENV_FILE"
    env_set POSTGRES_CPUS 0 "$ENV_FILE"
    env_set POSTGRES_MEMORY 0 "$ENV_FILE"
    env_set REDIS_CPUS 0 "$ENV_FILE"
    env_set REDIS_MEMORY 0 "$ENV_FILE"
    env_set REDIS_MAXMEMORY 0 "$ENV_FILE"
    env_set MEILI_CPUS 0 "$ENV_FILE"
    env_set MEILI_MEMORY 0 "$ENV_FILE"
    env_set WORKSPACE_CPUS 0 "$ENV_FILE"
    env_set WORKSPACE_MEMORY 0 "$ENV_FILE"
    env_set MAILPIT_CPUS 0 "$ENV_FILE"
    env_set MAILPIT_MEMORY 0 "$ENV_FILE"
    env_set CERTBOT_CPUS 0 "$ENV_FILE"
    env_set CERTBOT_MEMORY 0 "$ENV_FILE"
  else
    env_set NGINX_CPUS "$INFRA_NGINX_CPU" "$ENV_FILE"
    env_set NGINX_MEMORY "$(mb_to_compose "$INFRA_NGINX_MB")" "$ENV_FILE"

    env_set POSTGRES_CPUS "$INFRA_PG_CPU" "$ENV_FILE"
    env_set POSTGRES_MEMORY "$(mb_to_compose "$INFRA_PG_MB")" "$ENV_FILE"

    env_set REDIS_CPUS "$INFRA_REDIS_CPU" "$ENV_FILE"
    env_set REDIS_MEMORY "$(mb_to_compose "$INFRA_REDIS_MB")" "$ENV_FILE"
    local redis_max
    redis_max="$(imax 32 "$((INFRA_REDIS_MB * 2 / 3))")"
    env_set REDIS_MAXMEMORY "${redis_max}mb" "$ENV_FILE"

    if [[ "$INFRA_MEILI_MB" -gt 0 ]]; then
      env_set MEILI_CPUS "$INFRA_MEILI_CPU" "$ENV_FILE"
      env_set MEILI_MEMORY "$(mb_to_compose "$INFRA_MEILI_MB")" "$ENV_FILE"
    fi
    if [[ "$INFRA_WS_MB" -gt 0 ]]; then
      env_set WORKSPACE_CPUS "$INFRA_WS_CPU" "$ENV_FILE"
      env_set WORKSPACE_MEMORY "$(mb_to_compose "$INFRA_WS_MB")" "$ENV_FILE"
    fi
    if [[ "$INFRA_MAIL_MB" -gt 0 ]]; then
      env_set MAILPIT_CPUS "$INFRA_MAIL_CPU" "$ENV_FILE"
      env_set MAILPIT_MEMORY "$(mb_to_compose "$INFRA_MAIL_MB")" "$ENV_FILE"
    fi
    if [[ "$INFRA_CERT_MB" -gt 0 ]]; then
      env_set CERTBOT_CPUS "$INFRA_CERT_CPU" "$ENV_FILE"
      env_set CERTBOT_MEMORY "$(mb_to_compose "$INFRA_CERT_MB")" "$ENV_FILE"
    fi
  fi

  # Postgres -c tuning still follows host size (even when cgroup limits are off)
  local pg_shared pg_cache pg_conn
  pg_shared="$(imax 64 "$((INFRA_PG_MB / 4))")"
  pg_cache="$(imax 128 "$((INFRA_PG_MB * 2 / 3))")"
  pg_conn="$(imax 30 "$(imin 200 "$((50 + PLAN_EXISTING * 40 + PLAN_EXTRA * 40))")")"
  env_set POSTGRES_SHARED_BUFFERS "$(mb_to_postgres "$pg_shared")" "$ENV_FILE"
  env_set POSTGRES_EFFECTIVE_CACHE "$(mb_to_postgres "$pg_cache")" "$ENV_FILE"
  env_set POSTGRES_MAX_CONNECTIONS "$pg_conn" "$ENV_FILE"

  if [[ "$unlimited" -eq 1 ]]; then
    env_set RESOURCE_PROFILE "unlimited" "$ENV_FILE"
  else
    env_set RESOURCE_PROFILE "auto" "$ENV_FILE"
  fi
  env_set RESOURCE_MODE "$(resource_mode)" "$ENV_FILE"
  env_set HOST_CPUS_DETECTED "$HOST_CPUS" "$ENV_FILE"
  env_set HOST_MEM_MB_DETECTED "$HOST_MEM_MB" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

apply_app_limits() {
  local app="$1"
  local runtime defaults
  defaults="$(site_defaults "$app")"
  runtime="$(app_runtime "$app")"

  if app_resource_pinned "$app"; then
    echo "  skip pinned app: $app (RESOURCE_PIN=1)"
    return 0
  fi

  if resource_mode_unlimited; then
    if [[ "$runtime" == "octane" ]]; then
      env_set OCTANE_CPUS 0 "$defaults"
      env_set OCTANE_MEMORY 0 "$defaults"
      local workers
      workers="$(imax 1 "$(imin 8 "$HOST_CPUS")")"
      env_set OCTANE_COMMAND "php artisan octane:start --server=swoole --host=0.0.0.0 --port=8000 --workers=${workers} --task-workers=1 --max-requests=500" "$defaults"
    else
      env_set PHP_CPUS 0 "$defaults"
      env_set PHP_MEMORY 0 "$defaults"
    fi
    env_set QUEUE_CPUS 0 "$defaults"
    env_set QUEUE_MEMORY 0 "$defaults"
    env_set REVERB_CPUS 0 "$defaults"
    env_set REVERB_MEMORY 0 "$defaults"
    env_set SCHEDULER_CPUS 0 "$defaults"
    env_set SCHEDULER_MEMORY 0 "$defaults"
  else
    app_budget "$app"
    split_app_budget "$APP_BUDGET_MB" "$APP_BUDGET_CPU" "$runtime"

    if [[ "$runtime" == "octane" ]]; then
      env_set OCTANE_CPUS "$HTTP_CPU" "$defaults"
      env_set OCTANE_MEMORY "$(mb_to_compose "$HTTP_MB")" "$defaults"
      local workers
      workers="$(awk -v c="$HTTP_CPU" 'BEGIN{w=int(c*2); if(w<1)w=1; if(w>8)w=8; print w}')"
      env_set OCTANE_COMMAND "php artisan octane:start --server=swoole --host=0.0.0.0 --port=8000 --workers=${workers} --task-workers=1 --max-requests=300" "$defaults"
    else
      env_set PHP_CPUS "$HTTP_CPU" "$defaults"
      env_set PHP_MEMORY "$(mb_to_compose "$HTTP_MB")" "$defaults"
    fi

    env_set QUEUE_CPUS "$QUEUE_CPU" "$defaults"
    env_set QUEUE_MEMORY "$(mb_to_compose "$QUEUE_MB")" "$defaults"
    env_set REVERB_CPUS "$REVERB_CPU" "$defaults"
    env_set REVERB_MEMORY "$(mb_to_compose "$REVERB_MB")" "$defaults"
    env_set SCHEDULER_CPUS "$SCHED_CPU" "$defaults"
    env_set SCHEDULER_MEMORY "$(mb_to_compose "$SCHED_MB")" "$defaults"
  fi

  # ensure weight key exists for visibility
  if [[ -z "$(env_get RESOURCE_WEIGHT "$defaults")" ]]; then
    env_set RESOURCE_WEIGHT 1 "$defaults"
  fi
  chmod 600 "$defaults"
}

# Total MB/CPU for one app given current SURPLUS_* and WEIGHT_TOTAL
app_budget() {
  local app="$1"
  local runtime min_mb min_cpu eff unit_mb unit_cpu total_mb total_cpu
  runtime="$(app_runtime "$app")"
  if [[ "$runtime" == "octane" ]]; then
    min_mb="${OCT_MIN_MB:-352}"
    min_cpu="${OCT_MIN_CPU:-0.60}"
  else
    min_mb="${FPM_MIN_MB:-288}"
    min_cpu="${FPM_MIN_CPU:-0.50}"
  fi
  eff="$(app_effective_weight "$app")"
  if awk -v w="${WEIGHT_TOTAL:-0}" 'BEGIN{exit !(w>0)}'; then
    unit_mb="$(awk -v s="${SURPLUS_MB:-0}" -v w="$WEIGHT_TOTAL" -v e="$eff" 'BEGIN{printf "%d", (s*e)/w}')"
    unit_cpu="$(awk -v s="${SURPLUS_CPU:-0}" -v w="$WEIGHT_TOTAL" -v e="$eff" 'BEGIN{printf "%.2f", (s*e)/w}')"
  else
    unit_mb=0
    unit_cpu="0"
  fi
  total_mb=$((min_mb + unit_mb))
  total_cpu="$(fadd "$min_cpu" "$unit_cpu")"
  if [[ "$runtime" == "octane" ]]; then
    total_mb="$(imin "$total_mb" 6144)"
    total_cpu="$(fmin "$total_cpu" 6.00)"
  else
    total_mb="$(imin "$total_mb" 4096)"
    total_cpu="$(fmin "$total_cpu" 4.00)"
  fi
  APP_BUDGET_MB=$total_mb
  APP_BUDGET_CPU=$total_cpu
}

write_plan_file() {
  {
    echo "# Generated by ./dock resources — do not edit"
    echo "HOST_CPUS=$HOST_CPUS"
    echo "HOST_MEM_MB=$HOST_MEM_MB"
    echo "RESOURCE_MODE=$(resource_mode)"
    echo "APP_N=$APP_N"
    echo "PLAN_OK=$PLAN_OK"
    echo "FPM_TOTAL_MB=$FPM_TOTAL_MB"
    echo "OCT_TOTAL_MB=$OCT_TOTAL_MB"
    echo "GENERATED_AT=$(date -Iseconds)"
  } > "$PLAN_FILE"
}

cmd_detect() {
  local c m
  c="$(host_cpus)"
  m="$(host_mem_mb)"
  echo "════════════════════════════════════════════════════════"
  echo " Detected host resources"
  echo "════════════════════════════════════════════════════════"
  echo "  CPU : ${c} core(s)"
  echo "  RAM : ${m} MB ($(mb_to_compose "$m"))"
  echo
  echo "CPUS=${c}"
  echo "MEM_MB=${m}"
}

cmd_assess() {
  build_plan 0 0
  print_plan
  write_plan_file
  echo
  echo "Next: ./dock resources apply   # write container limits from this host"
  echo "      ./dock new-app <name>    # checks capacity again before create"
}

cmd_plan() {
  local extra=0 octane=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --extra) extra="${2:-1}"; shift 2 ;;
      --octane) octane=1; shift ;;
      *) shift ;;
    esac
  done
  build_plan "$extra" "$octane"
  print_plan
  write_plan_file
  [[ "$PLAN_OK" -eq 1 ]]
}

# Exit codes: 0=ok, 2=warn/critical (prompt), 1=blocked
cmd_check() {
  local extra="${1:-1}"
  local octane=0
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --octane) octane=1; shift ;;
      *) shift ;;
    esac
  done
  build_plan "$extra" "$octane"
  print_plan
  write_plan_file
  if [[ "$PLAN_OK" -ne 1 ]]; then
    echo
    echo "HARD LIMIT reached — cannot safely add this app."
    echo "Fix: free resources, disable COMPOSE_PROFILES (dev/search), use a larger host,"
    echo "  or set RESOURCE_MODE=unlimited in .env then ./dock resources apply (OOM risk)."
    echo "Override only with: ./dock new-app … --force"
    return 1
  fi
  case "${PLAN_LEVEL:-ok}" in
    warn|critical)
      echo
      echo "Approaching host limits (level=${PLAN_LEVEL}). You will be prompted to confirm."
      return 2
      ;;
  esac
  return 0
}

cmd_apply() {
  local extra=0 octane=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --extra) extra="${2:-0}"; shift 2 ;;
      --octane) octane=1; shift ;;
      --force) shift ;;
      *) shift ;;
    esac
  done
  build_plan "$extra" "$octane"
  print_plan
  if [[ "$PLAN_OK" -ne 1 && "$APP_N" -gt 0 ]]; then
    echo "Cannot apply — current app set exceeds hard host limits."
    echo "Remove an app or move to a larger server, then re-run."
    return 1
  fi
  apply_infra_to_env
  clear_root_app_limit_overrides
  sync_profile_env "$ENV_FILE"
  local app
  local count=0
  for app in $(list_apps); do
    apply_app_limits "$app"
    echo "  scaled app: $app ($(app_runtime "$app"))"
    count=$((count + 1))
  done
  write_plan_file
  echo
  if resource_mode_unlimited; then
    if [[ "$count" -eq 0 ]]; then
      echo "Wrote RESOURCE_MODE=unlimited (no Docker CPU/RAM caps) to .env (no apps yet)."
    else
      echo "Wrote RESOURCE_MODE=unlimited (no Docker CPU/RAM caps) for ${count} app(s)."
    fi
    echo "Warning: the host OOM killer is the only safety net under memory pressure."
  elif [[ "$count" -eq 0 ]]; then
    echo "Wrote infra limits to .env (no apps yet)."
  else
    echo "Wrote limits to .env and sites/*/defaults.env (${count} app(s))."
  fi
  echo "Scout/Mail env synced from COMPOSE_PROFILES=$(profiles_csv || true)"
  echo "Apply to running stack: ./dock up --force-recreate"
}

cmd_status() {
  build_plan 0 0
  print_plan
  echo
  echo "Per-app limits (WEIGHT / PIN):"
  printf '  %-12s %-7s %5s %4s %10s %10s %10s %10s\n' "APP" "RUNTIME" "W" "PIN" "HTTP" "QUEUE" "REVERB" "SCHED"
  local app defaults runtime pin w
  local any=0
  for app in $(list_apps); do
    any=1
    defaults="$(site_defaults "$app")"
    runtime="$(app_runtime "$app")"
    w="$(app_resource_weight "$app")"
    pin="-"
    if app_resource_pinned "$app"; then pin="yes"; fi
    if [[ "$runtime" == "octane" ]]; then
      printf '  %-12s %-7s %5s %4s %10s %10s %10s %10s\n' \
        "$app" "$runtime" "$w" "$pin" \
        "$(env_get OCTANE_MEMORY "$defaults"):$(env_get OCTANE_CPUS "$defaults")" \
        "$(env_get QUEUE_MEMORY "$defaults"):$(env_get QUEUE_CPUS "$defaults")" \
        "$(env_get REVERB_MEMORY "$defaults"):$(env_get REVERB_CPUS "$defaults")" \
        "$(env_get SCHEDULER_MEMORY "$defaults"):$(env_get SCHEDULER_CPUS "$defaults")"
    else
      printf '  %-12s %-7s %5s %4s %10s %10s %10s %10s\n' \
        "$app" "$runtime" "$w" "$pin" \
        "$(env_get PHP_MEMORY "$defaults"):$(env_get PHP_CPUS "$defaults")" \
        "$(env_get QUEUE_MEMORY "$defaults"):$(env_get QUEUE_CPUS "$defaults")" \
        "$(env_get REVERB_MEMORY "$defaults"):$(env_get REVERB_CPUS "$defaults")" \
        "$(env_get SCHEDULER_MEMORY "$defaults"):$(env_get SCHEDULER_CPUS "$defaults")"
    fi
  done
  if [[ "$any" -eq 0 ]]; then
    echo "  (no apps yet — run ./dock new-app <name>)"
  fi
}

cmd_weight() {
  local app="${1:-}"
  local weight="${2:-}"
  if [[ -z "$app" || -z "$weight" ]]; then
    echo "Usage: resources.sh weight <app> <number>"
    echo "Example: ./dock resources weight portal 2"
    echo "         ./dock resources weight portal 1"
    echo "         ./dock resources pin portal     # freeze current limits"
    echo "         ./dock resources unpin portal"
    exit 1
  fi
  require_app "$app"
  if ! awk -v w="$weight" 'BEGIN{exit !(w+0 > 0)}'; then
    echo "Weight must be a positive number (got: $weight)"
    exit 1
  fi
  env_set RESOURCE_WEIGHT "$weight" "$(site_defaults "$app")"
  chmod 600 "$(site_defaults "$app")"
  echo "Set $app RESOURCE_WEIGHT=$weight — recalculating…"
  cmd_apply
}

cmd_pin() {
  local app="${1:-}"
  require_app "$app"
  env_set RESOURCE_PIN 1 "$(site_defaults "$app")"
  chmod 600 "$(site_defaults "$app")"
  echo "Pinned $app — auto-scale will skip it. Current limits kept."
}

cmd_unpin() {
  local app="${1:-}"
  require_app "$app"
  env_set RESOURCE_PIN 0 "$(site_defaults "$app")"
  chmod 600 "$(site_defaults "$app")"
  echo "Unpinned $app — recalculating…"
  cmd_apply
}

usage() {
  cat <<'EOF'
Usage: resources.sh <detect|assess|plan|check|apply|status|weight|pin|unpin> [options]

  detect | assess | plan | check | apply | status
  weight <app> <n>    Give an app a larger (or smaller) share, then rescale
  pin <app>           Freeze an app's limits (skipped by auto-scale)
  unpin <app>         Allow auto-scale again and rescale

Per-app knobs in sites/<app>/defaults.env:
  RESOURCE_WEIGHT=2   # default 1 — 2 = roughly double the surplus share
  RESOURCE_PIN=1      # keep current PHP_/OCTANE_/QUEUE_/… limits

Root .env:
  RESOURCE_MODE=auto       # default — cgroup CPU/RAM caps from host plan
  RESOURCE_MODE=unlimited  # no Docker limits; capacity hard-blocks become warnings

Always detects the real server first (not a fixed 2CPU/4GB profile).
Optional presets remain: ./dock profile small|medium|large
  (presets set RESOURCE_MODE=auto)

Env: HOST_CPUS_OVERRIDE, HOST_MEM_MB_OVERRIDE, RESOURCES_ASSUME_YES=1
EOF
}

main() {
  local cmd="${1:-assess}"
  shift || true
  case "$cmd" in
    detect) cmd_detect "$@" ;;
    assess|capacity) cmd_assess "$@" ;;
    plan) cmd_plan "$@" ;;
    check) cmd_check "$@" ;;
    apply|scale) cmd_apply "$@" ;;
    status|show) cmd_status "$@" ;;
    weight) cmd_weight "$@" ;;
    pin) cmd_pin "$@" ;;
    unpin) cmd_unpin "$@" ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
