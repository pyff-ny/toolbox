#!/usr/bin/env bash
set -euo pipefail

# 1) 先加载统一配置
TOOLBOX_DIR="${TOOLBOX_DIR:-$HOME/toolbox}"
# shellcheck source=/dev/null
source "$TOOLBOX_DIR/scripts/_lib/load_conf.sh"
# shellcheck source=/dev/null
source "$TOOLBOX_DIR/scripts/_lib/log.sh"
# 2) 加载 backup 模块配置
load_module_conf "backup" \
  "DEST_USER" "DEST_HOST" \
  "REMOTE_DEST_PATH"\
  "SRC_DIR" \
  "REMOTE_SUDO" || exit $?
CONF_PATH="${TOOLBOX_CONF_USED:-}"
export CONF_PATH


# =========================

# 强校验 （避免空配置误跑）
# ===== Required config validation =====
: "${DEST_USER:?DEST_USER is required}"
: "${DEST_HOST:?DEST_HOST is required}"
: "${REMOTE_DEST_PATH:?REMOTE_DEST_PATH is required}"
: "${SRC_DIR:?SRC_DIR is required}"

# 防止像 " " 这种只包含空格
if [[ -z "${DEST_USER// /}" || -z "${DEST_HOST// /}" ]]; then
  echo "[ERROR] DEST_USER / DEST_HOST cannot be blank or spaces."
  exit 2
fi

# ========================
# 专业preflight，最关键三项：能ssh，远端目录可写，远端rsync可用

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

RUN_ID="$(date '+%Y-%m-%d_%H-%M-%S')"
LOG="${LOG_DIR}/rsync_backup_${RUN_ID}.log"

# =========================
# EXCLUDES (你已验证过的 + vanished 优化)
# 注意：exclude 以 SRC 根目录为基准（即 /System/Volumes/Data/ 下面的路径）
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
  "Library/Application Support/FileProvider/"
  "Library/Group Containers/5U8NS4GX82.dayoneapp2/Data/Documents/DayOnePhotos/Thumbnails/"
  #"Library/Group Containers/5U8NS4GX82.dayoneapp2/Data/Documents/DayOnePhotos/Thumbnails/"
  #"Library/Group Containers/5U8NS4GX82.dayoneapp2/Data/Documents/DayOnePhotos/Thumbnails/"
  #"Library/Group Containers/5U8NS4GX82.dayoneapp2/Data/Documents/DayOnePhotos/Thumbnails/"
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

ssh_quick() {
  # quiet, non-interactive-friendly checks
  ssh -T \
    -o BatchMode=yes \
    -o ConnectTimeout=8 \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    "$@"
}

# =========================
# Args
# =========================
DRY_RUN="false"
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN="true"
fi

mkdir -p "$LOG_DIR"

RSYNC_BIN="$(pick_rsync)"
LOCAL_USER="$(whoami)"
LOCAL_HOST="$(scutil --get LocalHostName 2>/dev/null || hostname)"

# =========================
# Preflight: ping + ssh info
# =========================
{
  echo "===== RSYNC BACKUP START ====="
  echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Local user: $LOCAL_USER"
  echo "Local host: $LOCAL_HOST"
  echo "Rsync: $RSYNC_BIN ($($RSYNC_BIN --version | head -n 1))"
  echo "SRC_DIR : $SRC_DIR"
  echo "DEST: ${DEST_USER}@${DEST_HOST}:${REMOTE_DEST_PATH}"
  echo "DRY_RUN: $DRY_RUN"
  echo "REMOTE_SUDO: $REMOTE_SUDO"
  echo "=============================="
  echo
} | tee "$LOG"

# 1) ping 测试（不通也继续，但会提示）
if ping -c 2 "$DEST_HOST" >/dev/null 2>&1; then
  echo "[OK] ping $DEST_HOST" | tee -a "$LOG"
else
  echo "[WARN] ping failed: $DEST_HOST (可能是不同网段/访客Wi-Fi/VPN/主机名不对). 建议在 iMac 上运行: scutil --get LocalHostName，然后用 <name>.local" | tee -a "$LOG"
fi

# 2) 远端信息（能连上就记录 whoami + LocalHostName）
REMOTE_WHOAMI="(unreachable)"
REMOTE_LHN="(unreachable)"
if ssh_quick "${DEST_USER}@${DEST_HOST}" "echo ok" >/dev/null 2>&1; then
  REMOTE_WHOAMI="$(ssh "${DEST_USER}@${DEST_HOST}" "whoami" 2>/dev/null || echo '(unknown)')"
  REMOTE_LHN="$(ssh "${DEST_USER}@${DEST_HOST}" "scutil --get LocalHostName 2>/dev/null || hostname" 2>/dev/null || echo '(unknown)')"
  echo "[OK] ssh reachable. remote whoami=$REMOTE_WHOAMI, remote LocalHostName=$REMOTE_LHN" | tee -a "$LOG"
else
  echo "[ERROR] ssh not reachable. 请在 iMac 打开：系统设置 → 通用 → 共享 → Remote Login（SSH）" | tee -a "$LOG"
  echo "        也可以用 iMac 的 IP（在 iMac 上运行: ipconfig getifaddr en0），把 DEST_HOST 改成那个 IP 再试。" | tee -a "$LOG"
  exit 10
fi

# 远端目标目录
ssh "${DEST_USER}@${DEST_HOST}" "mkdir -p '${REMOTE_DEST_PATH}'" 2>&1 | tee -a "$LOG" >/dev/null || true
REMOTE_USER_DIR="${REMOTE_DEST_PATH}/Users/${LOCAL_USER}"
ssh "${DEST_USER}@${DEST_HOST}" "mkdir -p '${REMOTE_USER_DIR}'" 2>&1 | tee -a "$LOG" >/dev/null

# Run rsync
start_epoch="$(date +%s)"

ARGS=(
  -aHhx
  --numeric-ids
  --delete
  --info=stats2,progress2,name1
  --partial
)

if [[ "$DRY_RUN" == "true" ]]; then
  ARGS+=( --dry-run --itemize-changes )
else
  REMOTE_TRASH_DIR="${REMOTE_DEST_PATH}/.rsync-trash/${RUN_ID}"
  ssh "${DEST_USER}@${DEST_HOST}" "mkdir -p '${REMOTE_TRASH_DIR}'" 2>&1 | tee -a "$LOG" >/dev/null
  ARGS+=( --backup --backup-dir="$REMOTE_TRASH_DIR" "--suffix=" )
fi


# DRY_RUN: 只审查
if [[ "$DRY_RUN" == "true" ]]; then
  ARGS+=( --dry-run --itemize-changes )
else
  # REAL RUN: 启用误删除保护
  REMOTE_TRASH_DIR="${REMOTE_DEST_PATH}/.rsync-trash/${RUN_ID}"

  # 确保远端回收站目录存在
  ssh "${DEST_USER}@${DEST_HOST}" "mkdir -p '${REMOTE_TRASH_DIR}'"

  ARGS+=( --backup --backup-dir="$REMOTE_TRASH_DIR" "--suffix=" )
fi


for ex in "${EXCLUDES[@]}"; do
  ARGS+=( --exclude="$ex" )
done



SSH_OPTS='ssh -T -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -o ConnectTimeout=12'
ARGS+=( -e "$SSH_OPTS" )
REMOTE_RSYNC="/opt/homebrew/bin/rsync"
REMOTE_RSYNC_FALLBACK="/usr/local/bin/rsync"

# 先探测远端哪一个存在（可写进日志）
REMOTE_RSYNC_RESOLVED="$(ssh "${DEST_USER}@${DEST_HOST}" \
  "test -x '$REMOTE_RSYNC' && echo '$REMOTE_RSYNC' || (test -x '$REMOTE_RSYNC_FALLBACK' && echo '$REMOTE_RSYNC_FALLBACK' || echo /usr/bin/rsync)")"

echo "Remote rsync resolved: $REMOTE_RSYNC_RESOLVED" | tee -a "$LOG"

# 强制远端用解析出来的 rsync
ARGS+=( --rsync-path="$REMOTE_RSYNC_RESOLVED" )


# 目标路径：按“本机用户名”分目录，避免混在一起（你也可以改）
REMOTE_TARGET="${DEST_USER}@${DEST_HOST}:${REMOTE_DEST_PATH}/Users/${LOCAL_USER}/"

echo "" | tee -a "$LOG"
#echo "---- RUN: sudo rsync ... -> $REMOTE_TARGET ----" | tee -a "$LOG"

set +e
# caffeinate -dimsu 包裹rsync命令，不休息运行
caffeinate -dimsu "$RSYNC_BIN" "${ARGS[@]}" "$SRC_DIR/" "$REMOTE_TARGET" 2>&1 | tee -a "$LOG"
RSYNC_CODE="${PIPESTATUS[0]}"
set -e

end_epoch="$(date +%s)"
elapsed="$(( end_epoch - start_epoch ))"

# =========================
# Summary parse
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

# 确保目录路径包含在.rsync-trash
case "$TRASH_ROOT" in
  *"/.rsync-trash"*) ;;
  *) echo "[ERROR] TRASH_ROOT looks unsafe: $TRASH_ROOT" ; exit 2 ;;
esac

# 清理策略，只在非dry-run，且rsync退出码是0/24时清理
if [[ "$DRY_RUN" != "true" ]] && ([[ "$RSYNC_CODE" -eq 0 ]] || [[ "$RSYNC_CODE" -eq 24 ]]); then
  ssh "${DEST_USER}@${DEST_HOST}" \
    "find '${TRASH_ROOT}' -mindepth 1 -maxdepth 1 -type d -mtime +${TRASH_RETENTION_DAYS} -exec rm -rf {} \;" \
    2>&1 | tee -a "$LOG" >/dev/null
fi

summary="SUMMARY | status=${status} | code=${RSYNC_CODE} | dry_run=${DRY_RUN} | transferred=${transferred_mb}MB | reg_xfer=${regular_transferred} | created=${created_files} | deleted=${deleted_files} | elapsed=${elapsed_hms} | remote=${DEST_USER}@${DEST_HOST} | trash=${REMOTE_TRASH_DIR:-N/A} | log=$(basename "$LOG")"


{
  echo
  echo "===== RSYNC BACKUP END ====="
  echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Local rsync: $RSYNC_BIN ($($RSYNC_BIN --version | head -n 1))" | tee -a "$LOG"
  echo "Remote rsync: $(ssh ${DEST_USER}@${DEST_HOST} '$REMOTE_RSYNC_RESOLVED --version | head -n 1' 2>/dev/null)" | tee -a "$LOG"
  

  echo "$summary"
  echo "============================"
} | tee -a "$LOG"

exit "$RSYNC_CODE"

