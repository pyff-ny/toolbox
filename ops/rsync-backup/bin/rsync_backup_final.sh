#!/usr/bin/env bash
set -euo pipefail

# 加载配置
# ===== Load config =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 检查 load_conf.sh 是否存在
if [[ -f "$SCRIPT_DIR/load_conf.sh" ]]; then
  source "$SCRIPT_DIR/load_conf.sh"
  load_module_conf "backup"
  echo "[INFO] Loaded backup config from load_conf.sh"
elif [[ -f "$HOME/toolbox/_lib/load_conf.sh" ]]; then
  source "$HOME/toolbox/_lib/load_conf.sh"
  load_module_conf "backup"
  echo "[INFO] Loaded backup config from _lib/load_conf.sh"
fi

# 直接加载 backup.env
ENV_FILE="${ENV_FILE:-$HOME/toolbox/conf/backup.env}"

if [[ -f "$ENV_FILE" ]]; then
  echo "[INFO] Loading config: $ENV_FILE"
  source "$ENV_FILE"
else
  echo "[ERROR] Missing config: $ENV_FILE"
  echo "Create it from conf/backup.env.example"
  exit 2
fi

# =========================
# 强校验 （避免空配置误跑）
# =========================
: "${DEST_USER:?DEST_USER is required}"
: "${DEST_HOST:?DEST_HOST is required}"
: "${REMOTE_DEST_PATH:?REMOTE_DEST_PATH is required}"
: "${SRC:?SRC is required}"

# 防止像 " " 这种只包含空格
if [[ -z "${DEST_USER// /}" || -z "${DEST_HOST// /}" ]]; then
  echo "[ERROR] DEST_USER / DEST_HOST cannot be blank or spaces."
  exit 2
fi

# 检查源目录是否存在
if [[ ! -d "$SRC" ]]; then
  echo "[ERROR] Source directory does not exist: $SRC"
  echo "Please check your SRC setting in $ENV_FILE"
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
LOG_DIR="${LOG_DIR:-$HOME/toolbox/Logs}"
mkdir -p "$LOG_DIR"

RUN_ID="$(date '+%Y-%m-%d_%H-%M-%S')"
LOG="${LOG_DIR}/rsync_backup_${RUN_ID}.log"

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

RSYNC_BIN="$(pick_rsync)"
LOCAL_USER="$(whoami)"
LOCAL_HOST="$(scutil --get LocalHostName 2>/dev/null || hostname)"

# =========================
# Preflight Log
# =========================
{
  echo "===== RSYNC BACKUP START ====="
  echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Local user: $LOCAL_USER"
  echo "Local host: $LOCAL_HOST"
  echo "Rsync: $RSYNC_BIN ($($RSYNC_BIN --version | head -n 1))"
  echo "SRC : $SRC"
  echo "DEST: ${DEST_USER}@${DEST_HOST}:${REMOTE_DEST_PATH}"
  echo "DRY_RUN: $DRY_RUN"
  echo "=============================="
  echo
} | tee "$LOG"

# 1) ping 测试
if ping -c 2 "$DEST_HOST" >/dev/null 2>&1; then
  echo "[OK] ping $DEST_HOST" | tee -a "$LOG"
else
  echo "[WARN] ping failed: $DEST_HOST" | tee -a "$LOG"
fi

# 2) 远端信息
REMOTE_WHOAMI="$(ssh "${DEST_USER}@${DEST_HOST}" "whoami" 2>/dev/null || echo '(unknown)')"
REMOTE_LHN="$(ssh "${DEST_USER}@${DEST_HOST}" "scutil --get LocalHostName 2>/dev/null || hostname" 2>/dev/null || echo '(unknown)')"
echo "[OK] ssh reachable. remote whoami=$REMOTE_WHOAMI, remote LocalHostName=$REMOTE_LHN" | tee -a "$LOG"

# 远端目标目录
REMOTE_USER_DIR="${REMOTE_DEST_PATH}/Users/${LOCAL_USER}"
ssh "${DEST_USER}@${DEST_HOST}" "mkdir -p '${REMOTE_USER_DIR}'" 2>&1 | tee -a "$LOG" >/dev/null

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
caffeinate -dimsu "$RSYNC_BIN" "${ARGS[@]}" "$SRC/" "$REMOTE_TARGET" 2>&1 | tee -a "$LOG"
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
if [[ "$RSYNC_CODE" -eq 24 ]]; then
  status="WARN(code24 vanished)"
elif [[ "$RSYNC_CODE" -eq 23 ]]; then
  status="ERROR(code23 partial)"
elif [[ "$RSYNC_CODE" -ne 0 ]]; then
  status="ERROR(code${RSYNC_CODE})"
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

summary="SUMMARY | status=${status} | code=${RSYNC_CODE} | dry_run=${DRY_RUN} | transferred=${transferred_mb}MB | reg_xfer=${regular_transferred} | created=${created_files} | deleted=${deleted_files} | elapsed=${elapsed_hms} | remote=${DEST_USER}@${DEST_HOST} | log=$(basename "$LOG")"

{
  echo
  echo "===== RSYNC BACKUP END ====="
  echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "$summary"
  echo "============================"
} | tee -a "$LOG"

exit "$RSYNC_CODE"
