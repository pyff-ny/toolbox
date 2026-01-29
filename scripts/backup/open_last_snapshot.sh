#!/usr/bin/env bash
set -euo pipefail

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

# ===== Load config =====
TOOLBOX_DIR="${TOOLBOX_DIR:-$HOME/toolbox}"
# shellcheck source=/dev/null
source "$TOOLBOX_DIR/scripts/_lib/load_conf.sh"
# shellcheck source=/dev/null
source "$TOOLBOX_DIR/scripts/_lib/log.sh"

load_module_conf "ssh_sync" \
  "DEST_HOST" "DEST_USER" \
  "REMOTE_ROOT" \
  "REMOTE_REPORTS_DIR" "REMOTE_LOGS_DIR" \
  "LOCAL_INDEX" || exit $?

CONF_PATH="${TOOLBOX_CONF_USED:-}"

# -------------------------
# 基础检查
# -------------------------
[[ -f "$LOCAL_INDEX" ]] || die "snapshot index not found: $LOCAL_INDEX"
LAST_LINE="$(tail -n 1 "$LOCAL_INDEX" 2>/dev/null || true)"
[[ -n "$LAST_LINE" ]] || die "snapshot index empty: $LOCAL_INDEX"

getv() {
  local key="$1"
  echo "$LAST_LINE" | tr '\t' '\n' | sed -n "s/^${key}=//p"
}

RUN_ID="$(getv RUN_ID)"
DRY_RUN="$(getv DRY_RUN)"
REPORTS="$(getv REPORTS)"
LOGS="$(getv LOGS)"
LOG_FILE="$(getv LOG)"

DRY_RUN="${DRY_RUN:-unknown}"

# -------------------------
# helpers
# -------------------------
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5)

open_local_file() {
  local label="$1" p="${2:-}"
  [[ -z "$p" ]] && return 0
  if [[ -f "$p" ]]; then
    open "$p" >/dev/null 2>&1 || true
    log_ok "LOCAL" "Opened ${label}: $p"
  else
    log_warn "LOCAL" "${label} not found: $p"
  fi
}

# return 0 if opened locally, 1 if missing locally (may need remote)
open_local_dir() {
  local label="$1" p="${2:-}"
  [[ -z "$p" ]] && return 0
  if [[ -d "$p" ]]; then
    open "$p" >/dev/null 2>&1 || true
    log_ok "LOCAL" "Opened ${label}: $p"
    return 0
  fi
  log_info "LOCAL" "${label} missing locally (will try remote if needed): $p"
  return 1
}

mk_target() {
  local host="${1:?host}" user="${2:-}"
  [[ -n "$user" && "$host" != *"@"* ]] && printf '%s@%s' "$user" "$host" || printf '%s' "$host"
}

remote_open_dir() {
  local target="${1:?target}" label="${2:?label}" path="${3:?path}"
  ssh "${SSH_OPTS[@]}" "$target" "open \"${path}\" >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  log_ok "NETWORK" "Requested iMac open ${label}: ${path}"
}

# -------------------------
# LOCAL section
# -------------------------
echo "== Open Last Snapshot =="
log_info "LOCAL" "RUN_ID:  ${RUN_ID:-N/A}"
log_info "LOCAL" "DRY_RUN: ${DRY_RUN:-unknown}"
[[ -n "${CONF_PATH:-}" && -f "$CONF_PATH" ]] && log_info "META" "Config: $CONF_PATH"

open_local_file "Log" "$LOG_FILE"

if [[ "$DRY_RUN" == "true" ]]; then
  log_ok "LOCAL" "DONE (DRY_RUN=true)"
  exit 0
fi

need_remote=0
open_local_dir "Reports" "${REPORTS:-}" || need_remote=1
open_local_dir "Logs"    "${LOGS:-}"    || need_remote=1

log_ok "LOCAL" "DONE"
echo

if [[ "$need_remote" -eq 0 ]]; then
  log_info "NETWORK" "Local snapshot dirs exist; skip SSH open."
  log_ok "REMOTE" "DONE"
  exit 0
fi

# -------------------------
# NETWORK section
# -------------------------
: "${DEST_HOST:?DEST_HOST is required}"
TARGET="$(mk_target "$DEST_HOST" "${DEST_USER:-}")"

log_info "NETWORK" "Connecting to iMac via SSH (timeout=5s)..."
if ! ssh "${SSH_OPTS[@]}" "$TARGET" "echo ok" >/dev/null 2>&1; then
  log_warn "NETWORK" "SSH preflight failed; skip remote open."
  log_ok "REMOTE" "DONE"
  exit 0
fi

REMOTE_REPORTS_ABS="${REMOTE_ROOT%/}/${REMOTE_REPORTS_DIR#/}"
REMOTE_LOGS_ABS="${REMOTE_ROOT%/}/${REMOTE_LOGS_DIR#/}"

remote_open_dir "$TARGET" "Reports" "$REMOTE_REPORTS_ABS"
remote_open_dir "$TARGET" "Logs"    "$REMOTE_LOGS_ABS"

log_ok "REMOTE" "DONE"
echo
exit 0
