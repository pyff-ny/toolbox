#!/usr/bin/env bash
set -euo pipefail
CANCELLED=0
RSYNC_CODE=0
EXIT_CODE=0
on_sigint() {
  CANCELLED=1
  echo "[INFO] Interrupted by user (Ctrl-C)."
}
trap on_sigint INT

echo "[DEBUG] argv: $*"


# ===== Load config =====

TOOLBOX_ROOT="${TOOLBOX_ROOT:-$HOME/toolbox}"
SCRIPT_DIR="${SCRIPT_DIR:-$TOOLBOX_ROOT/scripts}"
source "$SCRIPT_DIR/_lib/load_conf.sh"

load_module_conf "backup" \
  "SRC_DIR" "DST_DIR" "DEST_USER" "DEST_HOST" \
  "REMOTE_DEST_PATH" || exit $?
CONF_PATH="${TOOLBOX_CONF_USED:-}"
export CONF_PATH


# 这里开始使用 $SRC_DIR / $DST_DIR
echo "SRC=$SRC_DIR"
echo "DST=$DST_DIR"


LOG_DIR="${LOG_DIR:-$HOME/toolbox/_out/Logs}"
mkdir -p "$LOG_DIR"

# =========================
# 强校验 （避免空配置误跑）
# =========================
: "${DEST_USER:?DEST_USER is required}"
: "${DEST_HOST:?DEST_HOST is required}"
: "${DST_DIR:?DST_DIR is required}"
: "${REMOTE_DEST_PATH:?REMOTE_DEST_PATH is required}"
: "${SRC_DIR:?SRC_DIR is required}"

# 防止像 " " 这种只包含空格
if [[ -z "${DEST_USER// /}" || -z "${DEST_HOST// /}" ]]; then
  echo "[ERROR] DEST_USER / DEST_HOST cannot be blank or spaces."
  exit 2
fi

# 检查源目录是否存在
if [[ ! -d "$SRC_DIR" ]]; then
  echo "[ERROR] Source directory does not exist: $SRC_DIR"
  echo "Please check your SRC_DIR setting in ${CONF_PATH:-<no config>}"

  exit 2
fi

# =========================
# Preflight: SSH 检查
# =========================
SSH_OPTS=(-T -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=30 -o ServerAliveCountMax=3)

echo "[INFO] Checking SSH reachability..."
if ! ssh "${SSH_OPTS[@]}" "${DEST_USER}@${DEST_HOST}" "echo ok" >/dev/null 2>&1; then
  echo "[ERROR] SSH not reachable: ${DEST_USER}@${DEST_HOST}"
  echo "On iMac: System Settings → General → Sharing → Remote Login (SSH) ON"
  exit 10
fi

echo "[INFO] Checking remote path writable..."
if ! ssh "${SSH_OPTS[@]}" "${DEST_USER}@${DEST_HOST}" "mkdir -p '${REMOTE_DEST_PATH}' && test -w '${REMOTE_DEST_PATH}'" >/dev/null; then
  echo "[ERROR] Remote path not writable: ${REMOTE_DEST_PATH}"
  echo "Fix permissions on iMac or choose another REMOTE_DEST_PATH."
  exit 11
fi

echo "[INFO] Resolving remote rsync..."
REMOTE_RSYNC_RESOLVED="$(
  ssh "${SSH_OPTS[@]}" "${DEST_USER}@${DEST_HOST}" \
  "test -x /opt/homebrew/bin/rsync && echo /opt/homebrew/bin/rsync || \
   test -x /usr/local/bin/rsync && echo /usr/local/bin/rsync || \
   echo /usr/bin/rsync"
)"
echo "[INFO] Remote rsync: $REMOTE_RSYNC_RESOLVED"

# =========================
# LOG
# =========================

#生成时间戳和日志文件名
RUN_ID="$(date '+%Y-%m-%d_%H-%M-%S')"
LOG="${LOG_DIR}/rsync_backup_${RUN_ID}.log"

# 转换为绝对路径（重要！）
LOG_ABS="$(cd "$(dirname "$LOG")" && pwd)/$(basename "$LOG")"
#输出日志路径（调试用）
echo "[INFO] Log file: $LOG_ABS"

# =========================
# EXCLUDES
# =========================
EXCLUDES=(
  "/Library/Caches/"
  "/Users/*/Library/Caches/"
  "/private/var/vm/"
  "/private/var/folders/"
  "/private/var/tmp/"
  "/private/var/networkd/"
  "/private/var/protected/"
  "/.Spotlight-V100/"
  "/.Trashes/"
  "Library/Application Support/FileProvider/"
  "Library/Group Containers/"
  "Library/Containers/"
  "Library/Application Support/CloudDocs/"
  "Library/Mobile Documents/"
  "Documents/"
)

# =========================
# Helpers
# =========================
pick_rsync() {
  local bp
  if command -v brew >/dev/null 2>&1; then
    bp="$(brew --prefix)"
    if [[ -x "$bp/bin/rsync" ]]; then
      echo "$bp/bin/rsync"
      return
    fi
  fi
  echo "/usr/bin/rsync"
}

bytes_to_mb() {
  awk -v b="${1:-0}" 'BEGIN{printf "%.2f", (b/1024/1024)}'
}

fmt_hms() {
  local s="${1:-0}"
  local h=$(( s / 3600 ))
  local m=$(( (s % 3600) / 60 ))
  local r=$(( s % 60 ))
  printf "%02d:%02d:%02d" "$h" "$m" "$r"
}

extract_last_int() {
  local pat="$1"
  local file="$2"
  local line
  line="$(grep -E "$pat" "$file" | tail -n 1 || true)"
  [[ -z "$line" ]] && { echo "0"; return; }
  echo "$line" | grep -Eo '[0-9]+' | tail -n 1
}

extract_after_colon_bytes() {
  local pat="$1"
  local file="$2"
  local line
  line="$(grep -E "$pat" "$file" | tail -n 1 || true)"
  [[ -z "$line" ]] && { echo "0"; return; }
  echo "$line" | awk -F': ' '{print $2}' | awk '{print $1}' | tr -d ','
}

# =========================
# Args
# =========================
  DRY_RUN="false"
  if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN="true"
  fi

  run_mode=$([[ "${DRY_RUN:-false}" == "true" ]] && echo "DRY" || echo "REAL")

  RSYNC_BIN="$(pick_rsync)"
  LOCAL_USER="$(whoami)"
  LOCAL_HOST="$(scutil --get LocalHostName 2>/dev/null || hostname)"

# =========================
# Preflight Log
# =========================

{
  echo
  echo "===== RSYNC BACKUP START ====="
  echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Local user: $LOCAL_USER"
  echo "Local host: $LOCAL_HOST"
  echo "[INFO] Log: $LOG_ABS"
  echo "Rsync: $RSYNC_BIN ($($RSYNC_BIN --version | head -n 1))"
  echo "SRC : $SRC_DIR"
  echo "DEST: ${DEST_USER}@${DEST_HOST}:${REMOTE_DEST_PATH}"
  echo "DRY_RUN: $DRY_RUN"
  echo "=============================="
  echo
} | tee "$LOG_ABS"

# 1) ping 测试
if ping -c 2 "$DEST_HOST" >/dev/null 2>&1; then
  echo "[OK] ping $DEST_HOST" | tee -a "$LOG_ABS"
else
  echo "[WARN] ping failed: $DEST_HOST" | tee -a "$LOG_ABS"
fi

# 2) 远端信息
REMOTE_WHOAMI="$(ssh "${DEST_USER}@${DEST_HOST}" "whoami" 2>/dev/null || echo '(unknown)')"
REMOTE_LHN="$(ssh "${DEST_USER}@${DEST_HOST}" "scutil --get LocalHostName 2>/dev/null || hostname" 2>/dev/null || echo '(unknown)')"
echo "[OK] ssh reachable. remote whoami=$REMOTE_WHOAMI, remote LocalHostName=$REMOTE_LHN" | tee -a "$LOG_ABS"

# 远端目标目录
REMOTE_USER_DIR="${REMOTE_DEST_PATH}/Users/${LOCAL_USER}"
ssh "${DEST_USER}@${DEST_HOST}" "mkdir -p '${REMOTE_USER_DIR}'" 2>&1 | tee -a "$LOG_ABS" >/dev/null
# =========================
# Build rsync args
# =========================
start_epoch="$(date +%s)"

ARGS=(
  -aHhx
  --numeric-ids
  --delete
  --info=stats2,progress2,name1
  --partial
)

# DRY_RUN or REAL
if [[ "$DRY_RUN" == "true" ]]; then
  ARGS+=( --dry-run --itemize-changes )
else
  REMOTE_TRASH_DIR="${REMOTE_DEST_PATH}/.rsync-trash/${RUN_ID}"
  ssh "${DEST_USER}@${DEST_HOST}" "mkdir -p '${REMOTE_TRASH_DIR}'" 2>&1 | tee -a "$LOG" >/dev/null
  ARGS+=( --backup --backup-dir="$REMOTE_TRASH_DIR" "--suffix=" )
fi

# Excludes
for ex in "${EXCLUDES[@]}"; do
  ARGS+=( --exclude="$ex" )
done

# SSH options
SSH_OPTS_STR='ssh -T -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -o ConnectTimeout=12'
ARGS+=( -e "$SSH_OPTS_STR" )

# Remote rsync path
ARGS+=( --rsync-path="$REMOTE_RSYNC_RESOLVED" )

# Target
REMOTE_TARGET="${DEST_USER}@${DEST_HOST}:${REMOTE_USER_DIR}/"

echo "[INFO] Starting rsync..." | tee -a "$LOG"
echo "" | tee -a "$LOG"

# =========================
# Run rsync
# =========================
set +e
caffeinate -dimsu "$RSYNC_BIN" "${ARGS[@]}" "$SRC_DIR/" "$REMOTE_TARGET" 2>&1 | tee -a "$LOG"
RSYNC_CODE="${PIPESTATUS[0]}"
set -e

end_epoch="$(date +%s)"
elapsed="$(( end_epoch - start_epoch ))"

# =========================
# Summary
# =========================
deleted_files="$(extract_last_int '^Number of deleted files:' "$LOG")"
created_files="$(extract_last_int '^Number of created files:' "$LOG")"
regular_transferred="$(extract_last_int '^Number of regular files transferred:' "$LOG")"
transferred_bytes="$(extract_after_colon_bytes '^Total transferred file size:' "$LOG")"
transferred_mb="$(bytes_to_mb "$transferred_bytes")"
elapsed_hms="$(fmt_hms "$elapsed")"

status="OK"
EXIT_CODE=$RSYNC_CODE

if (( CANCELLED == 1 )); then
  status="CANCELLED"
  code=130   # 约定俗成：SIGINT 退出码
  EXIT_CODE=130

elif (( RSYNC_CODE == 24 )); then
  status="WARN(code24 vanished)"
  code=24
  EXIT_CODE=24
elif (( RSYNC_CODE == 23 )); then
  status="ERROR(code23 partial)"
  code=23
  EXIT_CODE=23
elif (( RSYNC_CODE != 0 )); then
  status="ERROR(code${RSYNC_CODE})"
  code=$RSYNC_CODE
  EXIT_CODE=$RSYNC_CODE
else
  code=0
  EXIT_CODE=0
fi

# 清理旧的回收站（只在成功时）
if [[ "$DRY_RUN" != "true" ]] && ([[ "$RSYNC_CODE" -eq 0 ]] || [[ "$RSYNC_CODE" -eq 24 ]]); then
  TRASH_ROOT="${REMOTE_DEST_PATH}/.rsync-trash"
  TRASH_RETENTION_DAYS="${TRASH_RETENTION_DAYS:-7}"
  
  echo "[INFO] Cleaning trash older than ${TRASH_RETENTION_DAYS} days..." | tee -a "$LOG"
  ssh "${DEST_USER}@${DEST_HOST}" \
    "find '${TRASH_ROOT}' -mindepth 1 -maxdepth 1 -type d -mtime +${TRASH_RETENTION_DAYS} -exec rm -rf {} \; 2>/dev/null || true" \
    2>&1 | tee -a "$LOG" >/dev/null || true
fi

 summary="SUMMARY | [$run_mode] | status=${status} | code=${EXIT_CODE} | dry_run=${DRY_RUN} | transferred=${transferred_mb}MB | \
 reg_xfer=${regular_transferred} | created=${created_files} | deleted=${deleted_files} | elapsed=${elapsed_hms} | \
 remote=${DEST_USER}@${DEST_HOST} | log=$(basename "$LOG_ABS")"


{
  echo
  echo "===== RSYNC BACKUP END ====="
  echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "[INFO] Script: $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  if [[ -n "${CONF_PATH:-}" ]]; then
     echo "[INFO] Config: $CONF_PATH"
  fi

  echo "[INFO] Log:$LOG_ABS"

  # --- Obsidian sink (append) ---
  obsidian_append_summary() {
  # 你可以按需改：Vault 根目录 / Note 路径
  local VAULT_DIR="${OBSIDIAN_VAULT_DIR:-$HOME/Obsidian/macOS}"
  local DAILY_DIR="${OBSIDIAN_DAILY_DIR:-Daily}"
  local day="$(date +"%Y-%m-%d")"
  local NOTE_PATH="$VAULT_DIR/$DAILY_DIR/$day.md"

  # 可选：把 source/dest/remote 等写进 frontmatter / 或者表格
  local ts="${timestamp:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
  local one_line="${SUMMARY_LINE:-}"

  mkdir -p "$(dirname "$NOTE_PATH")"

  {
    echo
    echo "## RSYNC Backup Run — ${ts}"
    [[ -n "$one_line" ]] && echo && echo "- ${one_line}"
    echo
    echo "**Script**: ${SCRIPT_PATH:-${BASH_SOURCE[0]}}"
    echo "**Config**: ${CONF_PATH:-N/A}"
    echo "**Log**: ${LOG_PATH:-$LOG_ABS}"
    echo

    # ---- JSON block (safe under set -u) ----
    local summary_json="${SUMMARY_JSON:-}"

    if [[ -n "$summary_json" ]]; then
      echo '```json'
      printf '%s\n' "$summary_json"
      echo '```'
    else
      echo '_SUMMARY_JSON is empty/unset_'
    fi

    echo
    echo
  } >> "$NOTE_PATH"
}
  # 调用函数追加到 Obsidian 笔记
  SUMMARY_JSON="$(cat <<EOF
{
  "status": "$status",
  "code": $EXIT_CODE,
  "rsync_code": $RSYNC_CODE,
  "dry_run": $DRY_RUN,
  "transferred_mb": $transferred_mb,
  "files_created": $created_files,
  "files_deleted": $deleted_files,
  "files_transferred": $regular_transferred,
  "elapsed_seconds": $elapsed,
  "elapsed_human": "$elapsed_hms",
  "log": "$LOG_ABS",
  "timestamp": "$(date '+%Y-%m-%dT%H:%M:%S')",
  "remote": "$DEST_USER@$DEST_HOST",
  "source": "$SRC_DIR",
  "destination": "$REMOTE_USER_DIR"
}
EOF
)"
  SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  LOG_PATH="$LOG_ABS"

  obsidian_append_summary
  echo "============================"
  echo "$summary"
  echo "============================"
  PRINT_SUMMARY_JSON_TERMINAL="${PRINT_SUMMARY_JSON_TERMINAL:-0}"
  if [[ "$PRINT_SUMMARY_JSON_TERMINAL" == 1 ]]; then
    echo "[SUMMARY_JSON] $SUMMARY_JSON"
  fi
} | tee -a "$LOG_ABS"

echo "[[[DEBUG] CANCELLED=$CANCELLED RSYNC_CODE=$RSYNC_CODE EXIT_CODE=${EXIT_CODE:-unset}"]]

exit "$EXIT_CODE"
