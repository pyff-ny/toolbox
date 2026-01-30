#!/usr/bin/env bash
set -euo pipefail

#先source配置 （拿到默认值）
#再CLI override (最终权威)
#再做delete 二次确认（基于最终值）
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
ts(){ date +"%Y%m%d_%H%M%S"; }

# ===== Load config =====
TOOLBOX_ROOT="${TOOLBOX_ROOT:-$HOME/toolbox}"
SCRIPT_DIR="${SCRIPT_DIR:-$TOOLBOX_ROOT/scripts}"
source "$SCRIPT_DIR/_lib/load_conf.sh"
source "$SCRIPT_DIR/_lib/log.sh"

# load module config helper
load_module_conf "ssh_sync" \
  "DEST_HOST" "DEST_USER" \
  "REMOTE_ROOT" \
  "LOCAL_REPORTS_DIR" "LOCAL_LOGS_DIR" \
  "REMOTE_REPORTS_DIR" "REMOTE_LOGS_DIR" \
  "SNAP_ROOT_REMOTE" \
  "LOG_DIR" || exit $?

# config path for logging
CONF_PATH="${TOOLBOX_CONF_USED:-}"


# ensure dirs exist for logs and conf
mkdir -p "$CONF_DIR" "$LOG_DIR"

# defaults from conf (fallback if missing in conf)
DRY_RUN="${DRY_RUN:-true}" # default to dry-run
DO_DELETE="${DO_DELETE:-false}" # default to no delete

RUN_TS="$(ts)"


# CLI override (final authority)
for arg in "$@"; do
  case "$arg" in
    --dry-run)    DRY_RUN=true ;;
    --real)       DRY_RUN=false ;;
    --delete)     DO_DELETE=true ;;
    --no-delete)  DO_DELETE=false ;;
    -h|--help)
      cat <<'EOF'
Usage: sync_reports [--dry-run|--real] [--delete|--no-delete]

Defaults:
  --dry-run
  --no-delete

Examples:
  sync_reports                # dry-run, no-delete
  sync_reports --real         # real run, no-delete
  sync_reports --real --delete# real run + delete (danger)
EOF
      exit 0
      ;;
    *)
      die "Unknown arg: $arg"
      ;;
  esac
done

: "${DEST_HOST:?DEST_HOST is required in $CFG}"
: "${LOCAL_REPORTS_DIR:?LOCAL_REPORTS_DIR is required in $CFG}"
: "${LOCAL_LOGS_DIR:?LOCAL_LOGS_DIR is required in $CFG}"
: "${REMOTE_REPORTS_DIR:?REMOTE_REPORTS_DIR is required in $CFG}"
: "${REMOTE_LOGS_DIR:?REMOTE_LOGS_DIR is required in $CFG}"

TARGET="$DEST_HOST"
if [[ -n "${DEST_USER:-}" && "$DEST_HOST" != *"@"* ]]; then
  TARGET="${DEST_USER}@${DEST_HOST}"
fi

command -v rsync >/dev/null 2>&1 || die "rsync not found"
command -v ssh   >/dev/null 2>&1 || die "ssh not found"

# rotate old logs
find "$LOG_DIR" -type f -name 'sync_reports_*.log' -mtime +30 -delete 2>/dev/null || true

SYNC_LOG="$LOG_DIR/sync_reports_$RUN_TS.log"
exec > >(tee -a "$SYNC_LOG") 2>&1

echo "== Sync Reports + Logs to iMac (SSH) =="
echo "Time: $(date)"
echo "Config: $CONF_PATH"
echo "Target: $TARGET"
echo "Local reports:  $LOCAL_REPORTS_DIR"
echo "Local logs:     $LOCAL_LOGS_DIR"
echo "Remote reports: $REMOTE_REPORTS_DIR"
echo "Remote logs:    $REMOTE_LOGS_DIR"
echo "DRY_RUN:    $DRY_RUN"
echo "DO_DELETE:  $DO_DELETE"
echo "Log file: $SYNC_LOG"
echo

mkdir -p "$LOCAL_REPORTS_DIR" "$LOCAL_LOGS_DIR"

# quick ssh preflight (avoid hang)
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$TARGET" "echo ok" >/dev/null 2>&1; then
  echo "SSH preflight failed (needs manual first-time auth?)."
  echo "Run once manually: ssh $TARGET"
  exit 4
fi

# ensure remote dirs exist
ssh "$TARGET" "mkdir -p \"$REMOTE_REPORTS_DIR\" \"$REMOTE_LOGS_DIR\""
is_safe_remote_path() {
  local p="$1"
  [[ -n "$p" ]] || return 1
  [[ "$p" != "/" ]] || return 1
  [[ "$p" != "." ]] || return 1
  [[ "$p" != ".." ]] || return 1
  [[ "$p" != *".."* ]] || return 1
  return 0
}

is_safe_remote_path "$REMOTE_REPORTS_DIR" || die "Unsafe remote path: $REMOTE_REPORTS_DIR"
is_safe_remote_path "$REMOTE_LOGS_DIR"    || die "Unsafe remote path: $REMOTE_LOGS_DIR"
# rsync args

RSYNC_ARGS=(-az --human-readable --progress)
[[ "$DRY_RUN" == "true"  ]] && RSYNC_ARGS+=(--dry-run --itemize-changes)
[[ "$DO_DELETE" == "true" ]] && RSYNC_ARGS+=(--delete)

# snapshot/rollback
SNAP_ROOT_REMOTE="${SNAP_ROOT_REMOTE:-/Volumes/iMac_HDD_Backup/_snapshots}"
SNAP_TS="$RUN_TS"
SNAP_REPORTS="$SNAP_ROOT_REMOTE/$SNAP_TS/IT-Reports"
SNAP_LOGS="$SNAP_ROOT_REMOTE/$SNAP_TS/IT-Logs"

# only create snapshot dir on REAL run
if [[ "$DRY_RUN" != "true" ]]; then
  ssh "$TARGET" "mkdir -p \"$SNAP_REPORTS\" \"$SNAP_LOGS\""
fi

run_rsync() {
  local src="$1" dest="$2" backup_dir="$3"
  echo
  echo "[RSYNC] $src -> $dest"
  set +e
  if [[ "$DRY_RUN" == "true" ]]; then
    rsync "${RSYNC_ARGS[@]}" "$src" "$dest"
  else
    rsync "${RSYNC_ARGS[@]}" --backup --backup-dir="$backup_dir" "$src" "$dest"
  fi
  local rc=$?
  set -e
  return $rc
}

run_rsync "$LOCAL_REPORTS_DIR"/ "$TARGET":"$REMOTE_REPORTS_DIR"/ "$SNAP_REPORTS" || die "Reports sync failed"
run_rsync "$LOCAL_LOGS_DIR"/    "$TARGET":"$REMOTE_LOGS_DIR"/    "$SNAP_LOGS"    || die "Logs sync failed"

# keep snapshots 30 days
ssh "$TARGET" "find \"$SNAP_ROOT_REMOTE\" -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} \; 2>/dev/null || true"

#打印快照文件路径
if [[ "$DRY_RUN" != "true" ]]; then
  echo "Snapshot saved (rollback dir):"
  echo "  Reports: $SNAP_REPORTS"
  echo "  Logs:    $SNAP_LOGS"
else
  log_info "LOCALLY" "Snapshot: (dry-run, not created)"
fi

# -------------------------
# Snapshot index (remote + local)
# -------------------------
SNAP_INDEX=""
if [[ "$DRY_RUN" != "true" ]]; then
  SNAP_INDEX="$SNAP_ROOT_REMOTE/index.tsv"

  INDEX_LINE="$(printf "RUN_ID=%s\tDRY_RUN=%s\tDO_DELETE=%s\tLOG=%s\tREPORTS=%s\tLOGS=%s\n" \
    "$RUN_TS" "$DRY_RUN" "$DO_DELETE" "$SYNC_LOG" "$SNAP_REPORTS" "$SNAP_LOGS")"

  ssh "$TARGET" "cat >> \"$SNAP_INDEX\" <<'EOF'
$INDEX_LINE
EOF"

  log_info "REMOTE" "Snapshot index updated: $SNAP_INDEX"

  LOCAL_INDEX="$LOG_DIR/snapshot_index.tsv"
  printf "RUN_ID=%s\tDRY_RUN=%s\tDO_DELETE=%s\tLOG=%s\tREPORTS=%s\tLOGS=%s\n" \
    "$RUN_TS" "$DRY_RUN" "$DO_DELETE" "$SYNC_LOG" "$SNAP_REPORTS" "$SNAP_LOGS" \
    >> "$LOCAL_INDEX"
else
  log_info "LOCALLY" "Snapshot index: (dry-run, not appended)"
fi

echo
log_info "LOCALLY" "RUN_ID: $RUN_TS"
log_info "LOCALLY" "DRY_RUN: $DRY_RUN"
log_info "LOCALLY" "DO_DELETE: $DO_DELETE"
log_info "REMOTE" "Target: $TARGET"
log_info "LOCALLY" "Local reports:  $LOCAL_REPORTS_DIR"
log_info "LOCALLY" "Local logs:     $LOCAL_LOGS_DIR"
log_info "REMOTE" "Remote reports: $REMOTE_REPORTS_DIR"
log_info "REMOTE" "Remote logs:    $REMOTE_LOGS_DIR"
log_info "LOCALLY" "Log file: $SYNC_LOG"
log_info "REMOTE" "Remote snapshot dir: $SNAP_REPORTS , $SNAP_LOGS"
log_info "REMOTE" "Remote snapshot index: ${SNAP_INDEX:-"(unset -dry-run or skipped)"}"
if [[ "$DRY_RUN" == "true" ]]; then
  log_info "LOCALLY" "Dry-run completed successfully (no changes applied)."
else
  log_ok "LOCALLY" "Sync completed successfully."
fi
log_warn "If you encounter issues, please check the log file above."


exit 0
