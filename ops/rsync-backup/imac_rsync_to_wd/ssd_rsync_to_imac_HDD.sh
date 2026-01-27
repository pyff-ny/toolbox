#!/bin/zsh
set -euo pipefail

# =========================
# User config
#使用时，先确认src/dest_vol是否正确
#这个版本是针对imac系统盘rsync到外置硬盘上的，镜像备份
# =========================
SRC="/Users/jiali/"
DEST_VOL="/Volumes/iMac_HDD_Backup/"          # ← 改成你的目标盘卷名挂载路径
DEST="${DEST_VOL}/imac_Backup/Users/jiali/"
mkdir -p "$DEST"

LOG_DIR="$HOME/Logs"
TS="$(date '+%Y-%m-%d_%H-%M-%S')"
LOG="${LOG_DIR}/rsync_backup_${TS}.log"

# Excludes (你已经验证过 0 报错的那套 + vanished 优化)
EXCLUDES=(
  "/Library/Caches/**"
  "/Users/*/Library/Caches/**"
  "/private/var/vm/**"
  "/private/var/folders/**"
  "/private/var/tmp/**"
  "/private/var/networkd/**"
  "/private/var/protected/**"
  "/.Spotlight-V100/**"
  "/.DocumentRevisions-V100/"
  "/.TemporaryItems/"
  "/.Trashes/**"
)

# =========================
# Helpers
# =========================
pick_rsync() {
  if [[ -x "/opt/homebrew/bin/rsync" ]]; then
    echo "/opt/homebrew/bin/rsync"
  elif [[ -x "/usr/local/bin/rsync" ]]; then
    echo "/usr/local/bin/rsync"
  else
    echo "/usr/bin/rsync"
  fi
}

bytes_to_mb() {
  # input: bytes
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
  # Usage: extract_last_int "pattern" logfile
  local pat="$1"
  local file="$2"
  # Find last matching line, then print last integer on that line
  local line
  line="$(grep -E "$pat" "$file" | tail -n 1 || true)"
  [[ -z "$line" ]] && { echo "0"; return; }
  echo "$line" | grep -Eo '[0-9]+' | tail -n 1
}

extract_after_colon_bytes() {
  # For lines like: Total transferred file size: 63,179,152 bytes
  local pat="$1"
  local file="$2"
  local line
  line="$(grep -E "$pat" "$file" | tail -n 1 || true)"
  [[ -z "$line" ]] && { echo "0"; return; }
  echo "$line" | awk -F': ' '{print $2}' | awk '{print $1}' | tr -d ','
}

# =========================
# Main
# =========================
DRY_RUN="false"
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN="true"
fi

mkdir -p "$LOG_DIR"
mkdir -p "$DEST"

if [[ ! -d "$DEST_VOL" ]]; then
  echo "ERROR: Destination volume not mounted: $DEST_VOL"
  exit 2
fi

RSYNC_BIN="$(pick_rsync)"

{
  echo "===== RSYNC BACKUP START ====="
  echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Rsync: $RSYNC_BIN ($($RSYNC_BIN --version | head -n 1))"
  echo "SRC : $SRC"
  echo "DEST: $DEST"
  echo "DRY_RUN: $DRY_RUN"
  echo "=============================="
  echo
} | tee -a "$LOG"

start_epoch="$(date +%s)"

# Build rsync args
ARGS=(
  -aHAXx
  --numeric-ids
  --delete
  --info=stats2,progress2
)

if [[ "$DRY_RUN" == "true" ]]; then
  ARGS+=( --dry-run )
fi

for ex in "${EXCLUDES[@]}"; do
  ARGS+=( --exclude="$ex" )
done

set +e
# Run rsync and log everything
sudo "$RSYNC_BIN" "${ARGS[@]}" "$SRC" "$DEST" 2>&1 | tee -a "$LOG"
RSYNC_CODE="${pipestatus[1]}"
set -e

end_epoch="$(date +%s)"
elapsed="$(( end_epoch - start_epoch ))"

# Parse stats from log (use last occurrence)
deleted_files="$(extract_last_int '^Number of deleted files:' "$LOG")"
created_files="$(extract_last_int '^Number of created files:' "$LOG")"
regular_transferred="$(extract_last_int '^Number of regular files transferred:' "$LOG")"
transferred_bytes="$(extract_after_colon_bytes '^Total transferred file size:' "$LOG")"
transferred_mb="$(bytes_to_mb "$transferred_bytes")"
elapsed_hms="$(fmt_hms "$elapsed")"

# Determine status text
status="OK"
if [[ "$RSYNC_CODE" -eq 24 ]]; then
  status="WARN(code24 vanished)"
elif [[ "$RSYNC_CODE" -eq 23 ]]; then
  status="ERROR(code23 partial)"
elif [[ "$RSYNC_CODE" -ne 0 ]]; then
  status="ERROR(code${RSYNC_CODE})"
fi

summary="SUMMARY | status=${status} | code=${RSYNC_CODE} | transferred=${transferred_mb}MB | reg_xfer=${regular_transferred} | created=${created_files} | deleted=${deleted_files} | elapsed=${elapsed_hms} | log=$(basename "$LOG")"

{
  echo
  echo "===== RSYNC BACKUP END ====="
  echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "$summary"
  echo "============================"
} | tee -a "$LOG"

# Exit with rsync code so you can detect failures in automation
exit "$RSYNC_CODE"
