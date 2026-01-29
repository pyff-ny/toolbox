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

# load module config helper
load_module_conf "ssh_sync" \
  "DEST_HOST" "DEST_USER" \
  "REMOTE_ROOT" \
  "LOCAL_REPORTS_DIR" "LOCAL_LOGS_DIR" \
  "REMOTE_REPORTS_DIR" "REMOTE_LOGS_DIR" \
  "SNAP_ROOT_REMOTE" || exit $?

# config path for logging
LOG_DIR="${LOG_DIR:-$TOOLBOX_ROOT/_out/Logs}"
CFG="${TOOLBOX_CONF_USED:-}"


# ensure dirs exist for logs and conf
mkdir -p "$CONF_DIR" "$LOG_DIR"

[[ -f "$CFG" ]] || die "Missing config: $CFG"
# shellcheck disable=SC1090
source "$CFG"

# defaults from conf (fallback if missing in conf)
DRY_RUN="${DRY_RUN:-false}"
DO_DELETE="${DO_DELETE:-false}"

RUN_TS="$(ts)"


# CLI override (final authority)
for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=true ;;
    --real)      DRY_RUN=false ;;
    --delete)    DO_DELETE=true ;;
    --no-delete) DO_DELETE=false ;;
    -h|--help)
      echo "Usage: sync_reports [--dry-run|--real] [--delete|--no-delete]"
      exit 0
      ;;
    *)
      die "Unknown arg: $arg"
      ;;
  esac
done

# delete safety confirm (based on FINAL values)
if [[ "$DO_DELETE" == "true" && "$DRY_RUN" != "true" ]]; then
  read -r -p "Type YES to confirm DELETE sync: " ans
  [[ "$ans" == "YES" ]] || { echo "Cancelled."; exit 1; }
fi

: "${SSH_HOST:?SSH_HOST is required in $CFG}"
: "${LOCAL_REPORTS:?LOCAL_REPORTS is required in $CFG}"
: "${LOCAL_LOGS:?LOCAL_LOGS is required in $CFG}"
: "${REMOTE_REPORTS:?REMOTE_REPORTS is required in $CFG}"
: "${REMOTE_LOGS:?REMOTE_LOGS is required in $CFG}"

TARGET="$SSH_HOST"
if [[ -n "${SSH_USER:-}" && "$SSH_HOST" != *"@"* ]]; then
  TARGET="${SSH_USER}@${SSH_HOST}"
fi

command -v rsync >/dev/null 2>&1 || die "rsync not found"
command -v ssh   >/dev/null 2>&1 || die "ssh not found"

# rotate old logs
find "$LOG_DIR" -type f -name 'sync_reports_*.log' -mtime +30 -delete 2>/dev/null || true

SYNC_LOG="$LOG_DIR/sync_reports_$RUN_TS.log"
exec > >(tee -a "$SYNC_LOG") 2>&1

echo "== Sync Reports + Logs to iMac (SSH) =="
echo "Time: $(date)"
echo "Config: $CFG"
echo "Target: $TARGET"
echo "Local reports:  $LOCAL_REPORTS"
echo "Local logs:     $LOCAL_LOGS"
echo "Remote reports: $REMOTE_REPORTS"
echo "Remote logs:    $REMOTE_LOGS"
echo "DRY_RUN:    $DRY_RUN"
echo "DO_DELETE:  $DO_DELETE"
echo "Log file: $SYNC_LOG"
echo

mkdir -p "$LOCAL_REPORTS" "$LOCAL_LOGS"

# quick ssh preflight (avoid hang)
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$TARGET" "echo ok" >/dev/null 2>&1; then
  echo "SSH preflight failed (needs manual first-time auth?)."
  echo "Run once manually: ssh $TARGET"
  exit 4
fi

# ensure remote dirs exist
ssh "$TARGET" "mkdir -p \"$REMOTE_REPORTS\" \"$REMOTE_LOGS\""

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

run_rsync "$LOCAL_REPORTS"/ "$TARGET":"$REMOTE_REPORTS"/ "$SNAP_REPORTS" || die "Reports sync failed"
run_rsync "$LOCAL_LOGS"/    "$TARGET":"$REMOTE_LOGS"/    "$SNAP_LOGS"    || die "Logs sync failed"

# keep snapshots 30 days
ssh "$TARGET" "find \"$SNAP_ROOT_REMOTE\" -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} \; 2>/dev/null || true"

#打印快照文件路径
if [[ "$DRY_RUN" != "true" ]]; then
  echo "Snapshot saved (rollback dir):"
  echo "  Reports: $SNAP_REPORTS"
  echo "  Logs:    $SNAP_LOGS"
else
  echo "Snapshot: (dry-run, not created)"
fi

# -------------------------
# Snapshot index (remote + local)
# -------------------------

if [[ "$DRY_RUN" != "true" ]]; then
  SNAP_INDEX="$SNAP_ROOT_REMOTE/index.tsv"

  INDEX_LINE="$(printf "RUN_ID=%s\tDRY_RUN=%s\tDO_DELETE=%s\tLOG=%s\tREPORTS=%s\tLOGS=%s\n" \
    "$RUN_TS" "$DRY_RUN" "$DO_DELETE" "$SYNC_LOG" "$SNAP_REPORTS" "$SNAP_LOGS")"

  ssh "$TARGET" "cat >> \"$SNAP_INDEX\" <<'EOF'
$INDEX_LINE
EOF"

  echo "Snapshot index updated: $SNAP_INDEX"

  LOCAL_INDEX="$LOG_DIR/snapshot_index.tsv"
  printf "RUN_ID=%s\tDRY_RUN=%s\tDO_DELETE=%s\tLOG=%s\tREPORTS=%s\tLOGS=%s\n" \
    "$RUN_TS" "$DRY_RUN" "$DO_DELETE" "$SYNC_LOG" "$SNAP_REPORTS" "$SNAP_LOGS" \
    >> "$LOCAL_INDEX"
else
  echo "Snapshot index: (dry-run, not appended)"
fi

echo
echo "DONE @ $RUN_TS"
echo "Log saved: $SYNC_LOG"
