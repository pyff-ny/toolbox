```bash
# 1. 项目结构（bin/conf/docs/logs/reports）
mkdir -p ~/Ops/disk-health/{bin,conf,docs,logs,reports}

# 2. 配置文件 (disk.env)

cat > ~/Ops/disk-health/conf/disk.env <<'EOF'
# 默认保留日志/报告多少天（0 不清理）
RETENTION_DAYS=60

# smartctl 路径（留空自动探测）
SMARTCTL=""

# 外置盘尝试的透传类型（按顺序）
DEVICE_TYPES_FILE="$HOME/Ops/disk-health/conf/device_types.txt"

# 输出目录
LOG_DIR="$HOME/Ops/disk-health/logs"
REPORT_DIR="$HOME/Ops/disk-health/reports"
EOF

# 外置透传类型列表（你可以自己增删）：

cat > ~/Ops/disk-health/conf/device_types.txt <<'EOF'
sat
sntasmedia
usbjmicron
EOF

# 3） 核心脚本 （bin/check_disk_health.sh)----支持“先选内置/外置/磁盘）”
# 把下面完整内容保存为：~/Ops/disk-health/bin/check_disk_health.sh
# 这是 zsh 版，风格跟你今天 rsync 脚本一致：preflight、日志、summary、report。

#!/bin/zsh
set -euo pipefail

# =========================
# Load config
# =========================
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
ENV_FILE="${PROJECT_DIR}/conf/disk.env"

if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
else
  echo "[ERROR] Missing config: $ENV_FILE"
  exit 2
fi

# Defaults
LOG_DIR="${LOG_DIR:-$PROJECT_DIR/logs}"
REPORT_DIR="${REPORT_DIR:-$PROJECT_DIR/reports}"
RETENTION_DAYS="${RETENTION_DAYS:-60}"

mkdir -p "$LOG_DIR" "$REPORT_DIR"

# =========================
# Helpers
# =========================
trim() { echo "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

pick_smartctl() {
  if [[ -n "${SMARTCTL:-}" && -x "${SMARTCTL}" ]]; then
    echo "$SMARTCTL"; return
  fi
  if command -v smartctl >/dev/null 2>&1; then
    command -v smartctl; return
  fi
  if command -v brew >/dev/null 2>&1; then
    local bp
    bp="$(brew --prefix)"
    [[ -x "$bp/sbin/smartctl" ]] && { echo "$bp/sbin/smartctl"; return; }
  fi
  echo ""
}

cleanup_old_files() {
  local dir="$1" days="$2"
  [[ "$days" -le 0 ]] && return 0
  [[ ! -d "$dir" ]] && return 0
  find "$dir" -type f -mtime +"$days" -print -delete 2>/dev/null || true
}

disk_is_internal() {
  local dev="$1"
  # diskutil info has: "Device Location: Internal" (newer) or "Internal: Yes"
  local info
  info="$(diskutil info "$dev" 2>/dev/null || true)"
  echo "$info" | grep -qiE 'Device Location: *Internal|Internal: *Yes'
}

disk_label() {
  local dev="$1"
  local info
  info="$(diskutil info "$dev" 2>/dev/null || true)"
  local name protocol size internal
  name="$(echo "$info" | awk -F': ' '/Volume Name:/{print $2; exit} /Media Name:/{print $2; exit}')"
  protocol="$(echo "$info" | awk -F': ' '/Protocol:/{print $2; exit}')"
  size="$(echo "$info" | awk -F': ' '/Disk Size:/{print $2; exit}')"
  if disk_is_internal "$dev"; then internal="Internal"; else internal="External"; fi
  echo "$dev | $internal | ${protocol:-Unknown} | ${size:-Unknown} | ${name:-"(no name)"}"
}

list_physical_disks() {
  # parse: /dev/disk0 (internal, physical):
  diskutil list | awk '
    /^\/dev\/disk[0-9]+/ && $0 ~ /physical/ {
      gsub(":", "", $1);
      print $1
    }'
}

choose_disk_menu() {
  local disks=()
  local d
  while IFS= read -r d; do
    [[ -n "$d" ]] && disks+=("$d")
  done < <(list_physical_disks)

  if (( ${#disks[@]} == 0 )); then
    echo "[ERROR] No physical disks found."
    exit 10
  fi

  echo "Select a disk to check:"
  local i=1
  for d in "${disks[@]}"; do
    echo "  [$i] $(disk_label "$d")"
    ((i++))
  done

  echo -n "Enter number (1-${#disks[@]}): "
  read -r choice
  [[ "$choice" =~ '^[0-9]+$' ]] || { echo "[ERROR] Invalid choice."; exit 11; }
  (( choice >= 1 && choice <= ${#disks[@]} )) || { echo "[ERROR] Out of range."; exit 12; }

  echo "${disks[$((choice-1))]}"
}

# ============ External check (smartctl) ============
external_check() {
  local dev="$1"
  local smartctl_bin="$2"
  local ts="$3"
  local log="$4"
  local report="$5"

  echo "[MODE] External (smartctl passthrough attempts)" | tee -a "$log"

  echo "[INFO] smartctl --scan-open" | tee -a "$log"
  sudo "$smartctl_bin" --scan-open 2>&1 | tee -a "$log" >/dev/null || true
  echo "" | tee -a "$log"

  local ok="false"
  local used="(none)"
  local out_file=""

  try_smart() {
    local dtype="$1"
    local out="${LOG_DIR}/smartctl_${ts}_${dtype:-direct}.out"
    echo "[TRY] smartctl -a ${dtype:+-d $dtype} $dev" | tee -a "$log"
    if [[ -n "$dtype" ]]; then
      if sudo "$smartctl_bin" -a -d "$dtype" "$dev" >"$out" 2>&1; then
        ok="true"; used="$dtype"; out_file="$out"
        echo "[OK] success with -d $dtype" | tee -a "$log"
        return 0
      fi
    else
      if sudo "$smartctl_bin" -a "$dev" >"$out" 2>&1; then
        ok="true"; used="(direct)"; out_file="$out"
        echo "[OK] success without -d" | tee -a "$log"
        return 0
      fi
    fi
    echo "[WARN] failed for ${dtype:-direct} (see $out)" | tee -a "$log"
    return 1
  }

  try_smart "" || true

  if [[ "$ok" != "true" && -f "${DEVICE_TYPES_FILE:-}" ]]; then
    while IFS= read -r line; do
      line="$(trim "$line")"
      [[ -z "$line" || "$line" == \#* ]] && continue
      try_smart "$line" && break || true
    done < "$DEVICE_TYPES_FILE"
  fi

  local status notes
  if [[ "$ok" == "true" ]]; then
    status="OK"
    notes="SMART readable."
  else
    status="UNSUPPORTED"
    notes="SMART likely not passed through by USB bridge/device."
  fi

  local info_line
  info_line="$(disk_label "$dev")"

  {
    echo "# Disk Health Report"
    echo ""
    echo "- Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "- Disk: \`$info_line\`"
    echo "- Mode: External (smartctl)"
    echo "- Status: **$status**"
    echo "- smartctl dtype: \`$used\`"
    echo "- Evidence: \`${out_file:-"(none)"}\`"
    echo ""
    echo "## Notes"
    echo "- $notes"
    echo ""
    echo "## Next actions"
    echo "- If UNSUPPORTED and you need SMART details: try a different enclosure/bridge that supports SMART passthrough."
    echo "- Keep the evidence output file for troubleshooting."
  } > "$report"

  echo "SUMMARY | mode=external | status=$status | device=$dev | dtype=$used | report=$(basename "$report")" | tee -a "$log"
  [[ "$status" == "OK" ]] && return 0 || return 20
}

# ============ Internal check (system_profiler + diskutil) ============
internal_check() {
  local dev="$1"
  local ts="$2"
  local log="$3"
  local report="$4"
  local smartctl_bin="$5"

  echo "[MODE] Internal (system_profiler + diskutil; smartctl optional)" | tee -a "$log"

  echo "[INFO] diskutil info $dev" | tee -a "$log"
  diskutil info "$dev" 2>&1 | tee -a "$log" >/dev/null || true
  echo "" | tee -a "$log"

  echo "[INFO] system_profiler SPNVMeDataType" | tee -a "$log"
  system_profiler SPNVMeDataType 2>&1 | tee -a "$log" >/dev/null || true
  echo "" | tee -a "$log"

  echo "[INFO] system_profiler SPSerialATADataType" | tee -a "$log"
  system_profiler SPSerialATADataType 2>&1 | tee -a "$log" >/dev/null || true
  echo "" | tee -a "$log"

  # Optional: try smartctl direct (may or may not work on Apple internal)
  local smart_notes="(not tried)"
  if [[ -n "$smartctl_bin" ]]; then
    echo "[INFO] Optional: smartctl -a $dev (may be limited on Apple internal drives)" | tee -a "$log"
    local out="${LOG_DIR}/smartctl_${ts}_internal_direct.out"
    if sudo "$smartctl_bin" -a "$dev" >"$out" 2>&1; then
      smart_notes="smartctl readable (see $out)"
      echo "[OK] smartctl produced output: $out" | tee -a "$log"
    else
      smart_notes="smartctl failed or limited (see $out)"
      echo "[WARN] smartctl failed/limited: $out" | tee -a "$log"
    fi
    echo "" | tee -a "$log"
  fi

  local info_line
  info_line="$(disk_label "$dev")"

  # Try to find “SMART Status” lines from system_profiler output saved in log
  local smart_status
  smart_status="$(grep -E 'SMART Status:' "$log" | tail -n 3 | tr -s ' ' | tail -n 1 || true)"
  [[ -z "$smart_status" ]] && smart_status="SMART Status: (n/a from system_profiler)"

  local status="OK"
  # If system_profiler shows "SMART Status: Failing" etc, mark Watch
  echo "$smart_status" | grep -qiE 'Fail|failing' && status="WATCH"

  {
    echo "# Disk Health Report"
    echo ""
    echo "- Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "- Disk: \`$info_line\`"
    echo "- Mode: Internal (system_profiler + diskutil)"
    echo "- Status: **$status**"
    echo ""
    echo "## Key signals"
    echo "- $smart_status"
    echo "- smartctl note: $smart_notes"
    echo ""
    echo "## Notes"
    echo "- Internal Apple SSDs often expose limited SMART details to smartctl; system_profiler is the primary source here."
    echo ""
    echo "## Next actions"
    echo "- If Status=WATCH or SMART reports failing: backup immediately and plan replacement/service."
    echo "- Keep logs for trend comparison."
  } > "$report"

  echo "SUMMARY | mode=internal | status=$status | device=$dev | report=$(basename "$report")" | tee -a "$log"
  [[ "$status" == "OK" ]] && return 0 || return 21
}

# =========================
# Main
# =========================
SMARTCTL_BIN="$(pick_smartctl)"  # may be empty; internal mode still works

TS="$(date '+%Y-%m-%d_%H-%M-%S')"
LOG="${LOG_DIR}/disk_health_${TS}.log"
REPORT="${REPORT_DIR}/report_${TS}.md"

{
  echo "===== DISK HEALTH CHECK START ====="
  echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Host: $(scutil --get LocalHostName 2>/dev/null || hostname)"
  echo "smartctl: ${SMARTCTL_BIN:-"(not installed)"}"
  echo "=================================="
  echo ""
} | tee "$LOG"

DISK_CHOSEN="$(choose_disk_menu)"
echo "" | tee -a "$LOG"
echo "[SELECTED] $DISK_CHOSEN" | tee -a "$LOG"
echo "" | tee -a "$LOG"

if disk_is_internal "$DISK_CHOSEN"; then
  internal_check "$DISK_CHOSEN" "$TS" "$LOG" "$REPORT" "$SMARTCTL_BIN"
else
  if [[ -z "$SMARTCTL_BIN" ]]; then
    echo "[ERROR] smartctl not found. Install: brew install smartmontools" | tee -a "$LOG"
    exit 3
  fi
  external_check "$DISK_CHOSEN" "$SMARTCTL_BIN" "$TS" "$LOG" "$REPORT"
fi

cleanup_old_files "$LOG_DIR" "$RETENTION_DAYS"
cleanup_old_files "$REPORT_DIR" "$RETENTION_DAYS"


#赋予可执行权限
chmod +x ~/Ops/disk-health/bin/check_disk_health.sh