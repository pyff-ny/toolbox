#!/usr/bin/env bash
# std.sh - shared header/footer helpers for toolbox scripts

# -------- identity / time --------
std_now_ts() { date +%Y%m%d_%H%M%S; }

# -------- safe default --------
std_default() {
  local name="${1:-}"      # 允许缺参
  local def="${2-}"        # 用 ${2-} 避免 set -u 触发
   echo "[DEBUG] std_default argc=$# name=${1-} def=${2-}" >&2

  [[ -n "$name" ]] || return 0

  # 若变量未设置或为空，才赋默认值
  if [[ -z "${!name-}" ]]; then
    printf -v "$name" '%s' "$def"
  fi
}

std_default_req() {
  [[ $# -ge 2 ]] || { echo "[ERROR] std_default_req needs 2 args: <varname> <default>" >&2; return 2; }
  std_default "$1" "$2"
}



# -------- summary helpers --------
std_print_header() {
  local title="${SCRIPT_TITLE:-Script}"
  local now
  now="$(date '+%a %b %d %H:%M:%S %Z %Y')"

  echo "== ${title} =="
  echo "Time: ${now}"
}


std_kv() { printf "%-12s %s\n" "$1:" "$2"; }

std_footer_summary() {
  # expects: RUN_TS
  echo
  log_ok "LOCALLY" "✅ Done! (RUN_TS="$(date '+%Y%m%d_%H%M%S')")"
  
}

std_debug_on()  { [[ "${DEBUG:-0}" == "1" ]] && set -x; }
std_debug_off() { set +x; }
