# scripts/_lib/log.sh
# shellcheck shell=bash
set -u

# levels: ERROR/WARN/INFO/OK/DEBUG
# stages: LOCAL/NETWORK/LONGRUN

LOG_LEVEL="${LOG_LEVEL:-INFO}"   # INFO or DEBUG
QUIET="${QUIET:-0}"              # 1 => suppress INFO/OK (keep WARN/ERROR)

_log_should_print() {
  local lvl="$1"
  if [[ "$lvl" == "ERROR" || "$lvl" == "WARN" ]]; then
    return 0
  fi
  [[ "${QUIET:-0}" == "1" ]] && return 1
  [[ "$lvl" == "DEBUG" ]] && [[ "${LOG_LEVEL:-INFO}" == "DEBUG" ]] || [[ "$lvl" != "DEBUG" ]]
}

log() {
  local lvl="$1"; shift
  local stage="${1:-}"; shift || true
  local msg="$*"

  _log_should_print "$lvl" || return 0

  if [[ -n "$stage" ]]; then
    printf '[%s][%s] %s\n' "$lvl" "$stage" "$msg"
  else
    printf '[%s] %s\n' "$lvl" "$msg"
  fi
}

log_ok()   { log "OK"   "${1:-}" "${2:-}"; }
log_info() { log "INFO" "${1:-}" "${2:-}"; }
log_warn() { log "WARN" "${1:-}" "${2:-}"; }
log_err()  { log "ERROR" "${1:-}" "${2:-}"; }
log_dbg()  { log "DEBUG" "${1:-}" "${2:-}"; }
