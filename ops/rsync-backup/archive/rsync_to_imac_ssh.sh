#!/bin/zsh
set -euo pipefail

# =========================
# CONFIG (edit these 3 first)
# =========================
# iMac 上用于 SSH 登录的“短用户名”（在 iMac 上运行 whoami 得到的）
DEST_USER="jiali"

# iMac 主机名：推荐用 scutil --get LocalHostName 得到的名字 + ".local"
# 例如：Jerrys-iMac.local
DEST_HOST="192.168.1.234" #"JiaLis-iMac.local"

# iMac 外置硬盘上接收备份的目录（确保 iMac 本机上该路径可写）
# 例如：/Volumes/iMac_HDD_Backup/Macbook_Data/
REMOTE_DEST_PATH="/Volumes/iMac_HDD_Backup/Macbook"
REMOTE_RSYNC="/usr/local/bin/rsync"
# 源：备份 MacBook 的 Data 卷（你之前就是这个）
SRC="$HOME/"

# 如果远端写入路径需要管理员权限，设为 true（会在远端用 sudo rsync）
REMOTE_SUDO="false"

# =========================
# LOG
# =========================
LOG_DIR="$HOME/Logs"
TS="$(date '+%Y-%m-%d_%H-%M-%S')"
LOG="${LOG_DIR}/rsync_backup_${TS}.log"

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
  echo "SRC : $SRC"
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

# 确保远端目录存在
ssh "${DEST_USER}@${DEST_HOST}" "mkdir -p '${REMOTE_DEST_PATH}'" 2>&1 | tee -a "$LOG" >/dev/null || true
REMOTE_USER_DIR="${REMOTE_DEST_PATH}/Users/${LOCAL_USER}"

ssh "${DEST_USER}@${DEST_HOST}" "mkdir -p \"${REMOTE_USER_DIR}\""

# =========================
# Run rsync
# =========================
start_epoch="$(date +%s)"

ARGS=(
  -aHhx
  --numeric-ids
  --delete
  --info=stats2,progress2,name1
  --partial
)

if [[ "$DRY_RUN" == "true" ]]; then
  ARGS+=( --dry-run )
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
caffeinate -dimsu "$RSYNC_BIN" "${ARGS[@]}" "$SRC" "$REMOTE_TARGET" 2>&1 | tee -a "$LOG"
RSYNC_CODE="${pipestatus[1]}"
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

summary="SUMMARY | status=${status} | code=${RSYNC_CODE} | transferred=${transferred_mb}MB | reg_xfer=${regular_transferred} | created=${created_files} | deleted=${deleted_files} | elapsed=${elapsed_hms} | remote=${DEST_USER}@${DEST_HOST} | log=$(basename "$LOG")"

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

