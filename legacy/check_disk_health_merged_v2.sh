#!/usr/bin/env bash
set -euo pipefail

# =========================
# Paths / embedded config
# =========================
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
PROJECT_DIR="$(cd -- "$(dirname -- "$SCRIPT_DIR")" && pwd -P)"


LOG_DIR_DEFAULT="$HOME/toolbox/_out/Logs"
REPORT_DIR_DEFAULT="$HOME/toolbox/_out/IT-Reports"
RETENTION_DAYS_DEFAULT=60
DEVICE_TYPES_FILE_DEFAULT="$PROJECT_DIR/conf/device_types.txt"
SMARTCTL_DEFAULT="/opt/homebrew/bin/smartctl"

# Allow env override
LOG_DIR="${LOG_DIR:-$LOG_DIR_DEFAULT}"
REPORT_DIR="${REPORT_DIR:-$REPORT_DIR_DEFAULT}"
RETENTION_DAYS="${RETENTION_DAYS:-$RETENTION_DAYS_DEFAULT}"
DEVICE_TYPES_FILE="${DEVICE_TYPES_FILE:-$DEVICE_TYPES_FILE_DEFAULT}"
DISK_ID="${DISK_ID:-}"          # e.g. disk0
SCAN_ALL="${SCAN_ALL:-0}"       # 1 = scan all physical disks
SMARTCTL="${SMARTCTL:-$SMARTCTL_DEFAULT}"

mkdir -p "$LOG_DIR" "$REPORT_DIR"

# =========================
# Helpers
# =========================
trim() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"${1:-}"; }

pick_smartctl() {
  if [[ -n "${SMARTCTL:-}" && -x "${SMARTCTL}" ]]; then
    echo "$SMARTCTL"; return
  fi
  if command -v smartctl >/dev/null 2>&1; then
    command -v smartctl; return
  fi
  if command -v brew >/dev/null 2>&1; then
    local bp
    bp="$(brew --prefix 2>/dev/null || true)"
    [[ -x "$bp/sbin/smartctl" ]] && { echo "$bp/sbin/smartctl"; return; }
  fi
  echo ""
}

cleanup_old_files() {
  local dir="$1" days="$2"
  [[ -z "$dir" || -z "$days" ]] && return 0
  [[ "$days" -le 0 ]] && return 0
  [[ ! -d "$dir" ]] && return 0
  find "$dir" -type f -mtime +"$days" -print -delete 2>/dev/null || true
}

disk_is_internal() {
  local dev="$1"
  local info
  info="$(diskutil info "$dev" 2>/dev/null || true)"
  grep -qiE 'Device Location: *Internal|Internal: *Yes' <<<"$info"
}

disk_label() {
  local dev="$1"
  local info name protocol size loc
  info="$(diskutil info "$dev" 2>/dev/null || true)"
  name="$(awk -F': ' '/Volume Name:/{print $2; exit} /Media Name:/{print $2; exit}' <<<"$info")"
  protocol="$(awk -F': ' '/Protocol:/{print $2; exit}' <<<"$info")"
  size="$(awk -F': ' '/Disk Size:/{print $2; exit}' <<<"$info")"
  if disk_is_internal "$dev"; then loc="Internal"; else loc="External"; fi
  echo "$dev | $loc | ${protocol:-Unknown} | ${size:-Unknown} | ${name:-"(no name)"}"
}

# Returns disk ids like: disk0 disk3 (physical only)
list_physical_disks() {
  diskutil list | awk '
    /^\/dev\/disk[0-9]+/ && $0 ~ /physical/ {
      gsub(":", "", $1);
      sub("^/dev/", "", $1);
      print $1
    }'
}

choose_disk_menu() {
  local disks=() d
  while IFS= read -r d; do
    [[ -n "$d" ]] && disks+=("$d")
  done < <(list_physical_disks)

  if (( ${#disks[@]} == 0 )); then
    echo "[ERROR] No physical disks found." >&2
    return 10
  fi

  echo "Select a disk to check:"
  local i=1
  for d in "${disks[@]}"; do
    echo "  [$i] $(disk_label "$d")"
    ((i++))
  done

  printf "Enter number (1-%s): " "${#disks[@]}"
  local choice
  read -r choice </dev/tty || { echo "[ERROR] read failed." >&2; return 11; }

  # Default to 1 if user just presses Enter
  if [[ -z "${choice:-}" ]]; then
    choice="1"
  fi

  [[ "$choice" =~ ^[0-9]+$ ]] || { echo "[ERROR] Invalid choice." >&2; return 11; }
  (( choice >= 1 && choice <= ${#disks[@]} )) || { echo "[ERROR] Out of range." >&2; return 12; }

  echo "${disks[$((choice-1))]}"
}

parse_smart_metrics() {
  local out="$1"
  [[ -f "$out" ]] || { echo ""; return 0; }

  # NOTE:
  # - NVMe drives expose fields like "Percentage Used", "Data Units Written" etc.
  # - SATA/SAS drives expose attributes table (ID# ... RAW_VALUE).
  # This parser is "best effort" and will leave fields empty if unsupported.

  local model serial health
  model="$(grep -E '^(Device Model:|Model Number:|Product:)' "$out" | head -n1 | awk -F': *' '{print $2}')"
  serial="$(grep -Ei '^(Serial Number:|Serial number:)' "$out" | head -n1 | awk -F': *' '{print $2}')"
  health="$(grep -E 'SMART overall-health self-assessment test result:|SMART Health Status:' "$out" | head -n1 | tr -s ' ')"

  # Common / NVMe-style fields
  local temp used poh unsafe media pcycles crit_warn avail_spare err_entries
  local du_read du_written

  temp="$(grep -E '^Temperature:|^Composite Temperature:|^Temperature Sensor 1:' "$out" | head -n1 | awk -F': *' '{print $2}')"
  used="$(grep -E '^Percentage Used:' "$out" | head -n1 | awk -F': *' '{print $2}')"
  poh="$(grep -E '^Power On Hours:' "$out" | head -n1 | awk -F': *' '{print $2}')"
  pcycles="$(grep -E '^Power Cycles:' "$out" | head -n1 | awk -F': *' '{print $2}')"
  unsafe="$(grep -E '^Unsafe Shutdowns:' "$out" | head -n1 | awk -F': *' '{print $2}')"
  media="$(grep -E '^Media and Data Integrity Errors:' "$out" | head -n1 | awk -F': *' '{print $2}')"
  err_entries="$(grep -E '^Error Information Log Entries:' "$out" | head -n1 | awk -F': *' '{print $2}')"
  crit_warn="$(grep -E '^Critical Warning:' "$out" | head -n1 | awk -F': *' '{print $2}')"
  avail_spare="$(grep -E '^Available Spare:' "$out" | head -n1 | awk -F': *' '{print $2}')"

  # Prefer the human-friendly bracketed units if present: "[x.xx TB]"
  du_read="$(grep -E '^Data Units Read:' "$out" | head -n1 | sed -n 's/.*\[\(.*\)\].*/\1/p')"
  [[ -z "${du_read:-}" ]] && du_read="$(grep -E '^Data Units Read:' "$out" | head -n1 | awk -F': *' '{print $2}')"

  du_written="$(grep -E '^Data Units Written:' "$out" | head -n1 | sed -n 's/.*\[\(.*\)\].*/\1/p')"
  [[ -z "${du_written:-}" ]] && du_written="$(grep -E '^Data Units Written:' "$out" | head -n1 | awk -F': *' '{print $2}')"

  # SATA attribute table (SSD wear / reliability indicators)
  # Extract RAW_VALUE (usually last column).
  sata_attr_raw() {
    local name="$1"
    awk -v n="$name" '$2==n {print $NF; exit}' "$out"
  }

  local realloc pending uncorrect wear lvl
  realloc="$(sata_attr_raw Reallocated_Sector_Ct)"
  pending="$(sata_attr_raw Current_Pending_Sector)"
  uncorrect="$(sata_attr_raw Offline_Uncorrectable)"
  wear="$(sata_attr_raw Media_Wearout_Indicator)"
  lvl="$(sata_attr_raw Wear_Leveling_Count)"

  local parts=()
  [[ -n "$model"  ]] && parts+=("model=$model")
  [[ -n "$serial" ]] && parts+=("serial=$serial")
  [[ -n "$health" ]] && parts+=("health=$health")
  [[ -n "$temp"   ]] && parts+=("temp=$temp")

  [[ -n "$poh"    ]] && parts+=("poh=$poh")
  [[ -n "$pcycles" ]] && parts+=("power_cycles=$pcycles")
  [[ -n "$unsafe" ]] && parts+=("unsafe_shutdowns=$unsafe")

  [[ -n "$used"   ]] && parts+=("percent_used=$used")
  [[ -n "$avail_spare" ]] && parts+=("avail_spare=$avail_spare")
  [[ -n "$crit_warn" ]] && parts+=("critical_warning=$crit_warn")

  [[ -n "$du_read" ]] && parts+=("data_read=$du_read")
  [[ -n "$du_written" ]] && parts+=("data_written=$du_written")

  [[ -n "$media"  ]] && parts+=("media_errors=$media")
  [[ -n "$err_entries" ]] && parts+=("error_log_entries=$err_entries")

  [[ -n "$realloc" ]] && parts+=("realloc_sectors=$realloc")
  [[ -n "$pending" ]] && parts+=("pending_sectors=$pending")
  [[ -n "$uncorrect" ]] && parts+=("uncorrectable=$uncorrect")
  [[ -n "$wear" ]] && parts+=("wear_indicator=$wear")
  [[ -n "$lvl" ]] && parts+=("wear_leveling=$lvl")

  local IFS=" | "
  echo "${parts[*]}"
}


# =========================
# SSD Monitor (quick stats)
# =========================
have_cmd() { command -v "$1" >/dev/null 2>&1; }

get_system_whole_disk() {
  # root volume -> diskXsY -> Part of Whole -> diskX
  local part whole
  part="$(diskutil info / 2>/dev/null | awk -F': *' '/Device Identifier/ {print $2; exit}')"
  [[ -n "${part:-}" ]] || { echo "UNKNOWN"; return; }
  whole="$(diskutil info "$part" 2>/dev/null | awk -F': *' '/Part of Whole/ {print $2; exit}')"
  echo "${whole:-UNKNOWN}"
}

get_diskutil_smart_status() {
  local whole="$1"
  diskutil info "$whole" 2>/dev/null | awk -F': *' '/SMART Status/ {print $2; exit}' || true
}

collect_smartctl_nvme_extended() {
  local whole="$1"
  local dev="/dev/$whole"
  local out
  out="$("$SMARTCTL_BIN" -a -d nvme "$dev" 2>/dev/null || true)"

  # helper: "Field: value"
  _f() { echo "$out" | awk -F': *' -v k="$1" '$1==k {print $2; exit}'; }

  local temp pct_used avail_spare poh pcycles unsafe media err_entries crit_warn
  temp="$(_f "Temperature")"
  [[ -z "${temp:-}" ]] && temp="$(_f "Composite Temperature")"
  # Keep digits if possible
  temp="$(echo "$temp" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){print $i; exit}}')"

  pct_used="$(_f "Percentage Used")"
  pct_used="$(echo "$pct_used" | sed 's/%//g' | awk '{print $1}')"

  avail_spare="$(_f "Available Spare")"
  poh="$(_f "Power On Hours")"; poh="$(echo "$poh" | awk '{print $1}')"
  pcycles="$(_f "Power Cycles")"; pcycles="$(echo "$pcycles" | awk '{print $1}')"
  unsafe="$(_f "Unsafe Shutdowns")"; unsafe="$(echo "$unsafe" | awk '{print $1}')"
  media="$(_f "Media and Data Integrity Errors")"; media="$(echo "$media" | awk '{print $1}')"
  err_entries="$(_f "Error Information Log Entries")"; err_entries="$(echo "$err_entries" | awk '{print $1}')"
  crit_warn="$(_f "Critical Warning")"

  local du_read du_written
  du_read="$(echo "$out" | sed -n 's/.*Data Units Read:.*\[\(.*\)\].*/\1/p' | head -n1)"
  [[ -z "${du_read:-}" ]] && du_read="$(_f "Data Units Read")"
  du_written="$(echo "$out" | sed -n 's/.*Data Units Written:.*\[\(.*\)\].*/\1/p' | head -n1)"
  [[ -z "${du_written:-}" ]] && du_written="$(_f "Data Units Written")"

  echo "${temp:-}|${pct_used:-}|${avail_spare:-}|${du_read:-}|${du_written:-}|${poh:-}|${pcycles:-}|${unsafe:-}|${media:-}|${err_entries:-}|${crit_warn:-}"
}

monitor_header_once() {
  local log_file="$1"
  if [[ ! -f "$log_file" ]]; then
    mkdir -p "$(dirname "$log_file")"
    echo "ts,whole,smart_status,temp_c,percent_used,avail_spare,data_read,data_written,power_on_hours,power_cycles,unsafe_shutdowns,media_errors,error_log_entries,critical_warning" > "$log_file"
  fi
}

monitor_notify() {
  local title="$1"; local msg="$2"
  if have_cmd osascript; then
    osascript -e "display notification \"${msg}\" with title \"${title}\"" >/dev/null 2>&1 || true
  fi
}

monitor_once() {
  local disk="${1:-}"
  local whole smart_status temp pct_used avail_spare du_read du_written poh pcycles unsafe media err_entries crit_warn
  whole="$disk"
  smart_status="$(get_diskutil_smart_status "$whole")"
  smart_status="${smart_status:-UNKNOWN}"

  temp=""; pct_used=""; avail_spare=""; du_read=""; du_written=""; poh=""; pcycles=""; unsafe=""; media=""; err_entries=""; crit_warn=""

  if [[ -x "$SMARTCTL_BIN" ]]; then
    IFS='|' read -r temp pct_used avail_spare du_read du_written poh pcycles unsafe media err_entries crit_warn < <(collect_smartctl_nvme_extended "$whole")
  fi

  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"

  printf "[MONITOR] %s | %s | SMART=%s | temp=%sC | used=%s%% | spare=%s | written=%s | read=%s | poh=%s | pcycles=%s | unsafe=%s | media=%s | err=%s\n" \
    "$ts" "$whole" "$smart_status" "${temp:-}" "${pct_used:-}" "${avail_spare:-}" "${du_written:-}" "${du_read:-}" "${poh:-}" "${pcycles:-}" "${unsafe:-}" "${media:-}" "${err_entries:-}" \
    | tee -a "$LOG"

  # CSV row (best-effort)
  echo "${ts},${whole},${smart_status},${temp},${pct_used},${avail_spare},\"${du_read}\",\"${du_written}\",${poh},${pcycles},${unsafe},${media},${err_entries},\"${crit_warn}\"" >> "$MONITOR_LOG"

  if [[ -n "${temp:-}" && "$temp" =~ ^[0-9]+$ ]]; then
    if (( temp >= ALERT_TEMP_C )); then
      monitor_notify "SSD 温度警报" "当前 ${temp}°C（阈值 ${ALERT_TEMP_C}°C），请检查散热/负载。"
    fi
  fi
}

run_monitor() {
  local whole="${1:-UNKNOWN}"
  if [[ "$whole" == "UNKNOWN" ]]; then
    echo "[ERROR] Cannot detect system disk." | tee -a "$LOG"
    exit 2
  fi

  # default log location
  if [[ -z "${MONITOR_LOG:-}" ]]; then
    MONITOR_LOG="${LOG_DIR}/ssd_monitor.csv"
  fi

  monitor_header_once "$MONITOR_LOG"

  if [[ "$MONITOR_ONCE" == "true" ]]; then
    monitor_once "$whole"
    exit 0
  fi

  while true; do
    monitor_once "$whole"
    sleep "$MONITOR_INTERVAL"
  done
}

# =========================
# Args
# =========================
DEVICE_OVERRIDE=""
DO_LIST="false"
DO_MONITOR="false"
MONITOR_INTERVAL="60"
MONITOR_ONCE="false"
MONITOR_LOG="${MONITOR_LOG:-}"
ALERT_TEMP_C="${ALERT_TEMP_C:-70}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE_OVERRIDE="${2:-}"; shift 2 ;;
    --list) DO_LIST="true"; shift ;;
    --monitor) DO_MONITOR="true"; shift ;;
    --interval) MONITOR_INTERVAL="${2:-60}"; shift 2 ;;
    --once) MONITOR_ONCE="true"; shift ;;
    --alert-temp) ALERT_TEMP_C="${2:-70}"; shift 2 ;;
    --monitor-log) MONITOR_LOG="${2:-}"; shift 2 ;;

    -h|--help)
      cat <<'H'
Usage:
  check_disk_health.sh                       # interactive disk health report (TTY)
  check_disk_health.sh --list                # list physical disks
  check_disk_health.sh --device disk0        # override disk id and run health report

Monitor mode (SSD/NVMe quick stats):
  check_disk_health.sh --monitor             # monitor system disk every 60s (prints + logs)
  check_disk_health.sh --monitor --once      # run once and exit
  check_disk_health.sh --monitor --interval 10
  check_disk_health.sh --monitor --alert-temp 75

Env:
  DISK_ID=disk0
  SMARTCTL=/opt/homebrew/bin/smartctl
  LOG_DIR=~/toolbox/_out/Logs
  REPORT_DIR=~/toolbox/_out/IT-Reports
  MONITOR_LOG=~/toolbox/_out/Logs/ssd_monitor.csv
  ALERT_TEMP_C=70

H
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [[ "$DO_LIST" == "true" ]]; then
  echo "Physical disks:"
  while IFS= read -r d; do
    [[ -n "$d" ]] && echo " - $(disk_label "$d")"
  done < <(list_physical_disks)
  exit 0
fi

SMARTCTL_BIN="$(pick_smartctl)"
RUN_ID="$(date '+%Y%m%d_%H%M%S')"           # 文件名用它（稳定、适合索引）
#HUMAN_TS="$(date '+%Y-%m-%d %H:%M:%S')"     # 内容显示用它（好读）

LOG="${LOG_DIR}/disk_health_${RUN_ID}.log"
REPORT="${REPORT_DIR}/report_${RUN_ID}.md"

# Monitor mode (SSD quick stats)
if [[ "$DO_MONITOR" == "true" ]]; then
  # Determine disk: explicit --device / DISK_ID env, otherwise system disk
  MON_DISK="${DEVICE_OVERRIDE:-${DISK_ID:-}}"
  if [[ -z "${MON_DISK:-}" ]]; then
    MON_DISK="$(get_system_whole_disk)"
  fi
  run_monitor "$MON_DISK"
  exit 0
fi



{
  echo "===== DISK HEALTH CHECK START ====="
  echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Host: $(scutil --get LocalHostName 2>/dev/null || hostname)"
  echo "smartctl: ${SMARTCTL_BIN:-'(not installed)'}"
  echo "=================================="
  echo ""
} | tee "$LOG"


scan_all_disks() {
  echo "[SCAN_ALL] Enumerating physical disks..." | tee -a "$LOG"
  local disks
  disks="$(list_physical_disks)"

  if [[ -z "${disks:-}" ]]; then
    echo "[SCAN_ALL][ERROR] No physical disks found via diskutil." | tee -a "$LOG"
    return 11
  fi

  echo "[SCAN_ALL] Found disks:" | tee -a "$LOG"
  echo "$disks" | sed 's/^/  - /' | tee -a "$LOG"
  echo "" | tee -a "$LOG"

  local d rc
  for d in $disks; do
    echo "------------------------------" | tee -a "$LOG"
    echo "[DISK] $d" | tee -a "$LOG"
    echo "Label: $(disk_label "$d" 2>/dev/null || echo "$d")" | tee -a "$LOG"

    if [[ -z "${SMARTCTL_BIN:-}" ]]; then
      echo "[DISK] smartctl not installed; skipping SMART for $d" | tee -a "$LOG"
      continue
    fi

    set +e
    sudo "$SMARTCTL_BIN" -a "/dev/$d" | tee -a "$LOG"
    rc=$?
    set -e

    if [[ $rc -ne 0 ]]; then
      echo "[DISK] $d smartctl rc=$rc - likely unsupported or permission issue" | tee -a "$LOG"
    else
      echo "[DISK] $d smartctl OK" | tee -a "$LOG"
    fi
    echo "" | tee -a "$LOG"
  done

  echo "[SCAN_ALL] Completed." | tee -a "$LOG"
}

# =========================
# Mode selection
# =========================
DISK_CHOSEN=""

if [[ -n "${DEVICE_OVERRIDE:-}" ]]; then
  DISK_CHOSEN="$DEVICE_OVERRIDE"
elif [[ -n "${DISK_ID:-}" ]]; then
  DISK_CHOSEN="$DISK_ID"
elif [[ "${SCAN_ALL:-0}" == "1" ]]; then
  echo "[MODE] scan_all" | tee -a "$LOG"
  echo "" | tee -a "$LOG"
  scan_all_disks
  echo "" | tee -a "$LOG"
  echo "[DONE] scan_all" | tee -a "$LOG"
  cleanup_old_files "$LOG_DIR" "$RETENTION_DAYS"
  cleanup_old_files "$REPORT_DIR" "$RETENTION_DAYS"
  exit 0
else
  # Default behavior: pick system disk automatically (no prompt).
  # Set INTERACTIVE_SELECT=1 to force menu selection.
  if [[ "${INTERACTIVE_SELECT:-0}" == "1" ]]; then
    if [[ -t 0 ]]; then
      DISK_CHOSEN="$(choose_disk_menu)"
    else
      echo "[ERROR] No TTY for interactive disk selection. Set DISK_ID (e.g. disk0) or SCAN_ALL=1." | tee -a "$LOG"
      exit 11
    fi
  else
    DISK_CHOSEN="$(get_system_whole_disk)"
    if [[ -z "${DISK_CHOSEN:-}" || "$DISK_CHOSEN" == "UNKNOWN" ]]; then
      echo "[ERROR] Cannot detect system disk. Set DISK_ID (e.g. disk0) or INTERACTIVE_SELECT=1." | tee -a "$LOG"
      exit 11
    fi
  fi
fi

echo "[MODE] single_disk" | tee -a "$LOG"
echo "[SELECTED] $(disk_label "$DISK_CHOSEN")" | tee -a "$LOG"
# ---- sudo warm-up (after disk selection) ----
# We do this after picking the disk to avoid confusing prompts (Password vs menu input).
if [[ -n "${SMARTCTL_BIN:-}" ]]; then
  if ! sudo -v; then
    echo "[ERROR] sudo auth failed. Cannot run smartctl." | tee -a "$LOG"
    exit 13
  fi
fi

echo "" | tee -a "$LOG"

IS_INTERNAL="false"
disk_is_internal "$DISK_CHOSEN" && IS_INTERNAL="true"
echo "[RESOLVED_MODE] $([[ "$IS_INTERNAL" == "true" ]] && echo internal || echo external)" | tee -a "$LOG"
echo "" | tee -a "$LOG"

# =========================
# Internal
# =========================
internal_check() {
  local dev="$1"
  local smartctl_bin="$2"
  local health_status="OK"
  local out_file=""
  local metrics=""

  echo "[MODE] Internal: system_profiler + diskutil + smartctl(if available)" | tee -a "$LOG"

  echo "[INFO] diskutil info $dev" | tee -a "$LOG"
  diskutil info "$dev" 2>&1 | tee -a "$LOG"
  echo "" | tee -a "$LOG"

  echo "[INFO] system_profiler -detailLevel mini SPNVMeDataType" | tee -a "$LOG"
  system_profiler -detailLevel mini SPNVMeDataType 2>&1 | tee -a "$LOG" || true
  echo "" | tee -a "$LOG"

  echo "[INFO] system_profiler -detailLevel mini SPSerialATADataType" | tee -a "$LOG"
  system_profiler -detailLevel mini SPSerialATADataType 2>&1 | tee -a "$LOG" || true
  echo "" | tee -a "$LOG"

  if [[ -n "$smartctl_bin" ]]; then
    out_file="${LOG_DIR}/smartctl_${RUN_ID}_internal.out"
    echo "[INFO] smartctl -a /dev/r$dev (internal)" | tee -a "$LOG"
    sudo "$smartctl_bin" -a "/dev/r$dev" >"$out_file" 2>&1 || true
    metrics="$(parse_smart_metrics "$out_file")"
    [[ -n "$metrics" ]] && echo "[INFO] parsed smart metrics: $metrics" | tee -a "$LOG"
    echo "" | tee -a "$LOG"
  fi

  {
    echo "# Disk Health Report"
    echo ""
    echo "- Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "- Disk: \`$(disk_label "$dev")\`"
    echo "- Mode: Internal"
    echo "- Status: **$health_status**"
    [[ -n "$metrics" ]] && echo "- SMART metrics: $metrics"
    echo ""
    echo "## Evidence"
    echo "- Log: \`$LOG\`"
    [[ -n "$out_file" ]] && echo "- smartctl output: \`$out_file\`"
  } > "$REPORT"

  echo "SUMMARY | mode=internal | status=$health_status | device=$dev | ${metrics:-} | report=$(basename "$REPORT")" | tee -a "$LOG"
}

# =========================
# External
# =========================
external_check() {
  local dev="$1"
  local smartctl_bin="$2"
  local health_status="UNSUPPORTED"
  local used="(none)"
  local out_file=""
  local metrics=""

  echo "[MODE] External: smartctl passthrough attempts" | tee -a "$LOG"

  if [[ -z "$smartctl_bin" ]]; then
    echo "[ERROR] smartctl not found. Install: brew install smartmontools" | tee -a "$LOG"
    exit 3
  fi

  echo "[INFO] smartctl --scan-open" | tee -a "$LOG"
  sudo "$smartctl_bin" --scan-open 2>&1 | tee -a "$LOG" || true
  echo "" | tee -a "$LOG"

  try_smart() {
    local dtype="$1"
    local tag="${dtype:-direct}"
    local out="${LOG_DIR}/smartctl_${RUN_ID}_${tag}.out"
    echo "[TRY] smartctl -a ${dtype:+-d $dtype} /dev/r$dev" | tee -a "$LOG"
    if [[ -n "$dtype" ]]; then
      sudo "$smartctl_bin" -a -d "$dtype" "/dev/r$dev" >"$out" 2>&1 && { used="$dtype"; out_file="$out"; return 0; }
    else
      sudo "$smartctl_bin" -a "/dev/r$dev" >"$out" 2>&1 && { used="(direct)"; out_file="$out"; return 0; }
    fi
    return 1
  }

  if try_smart ""; then
    health_status="OK"
  elif [[ -f "$DEVICE_TYPES_FILE" ]]; then
    while IFS= read -r line; do
      line="$(trim "$line")"
      [[ -z "$line" || "$line" == \#* ]] && continue
      if try_smart "$line"; then
        health_status="OK"
        break
      fi
    done < "$DEVICE_TYPES_FILE"
  fi

  if [[ "$health_status" == "OK" ]]; then
    metrics="$(parse_smart_metrics "$out_file")"
    [[ -n "$metrics" ]] && echo "[INFO] parsed smart metrics: $metrics" | tee -a "$LOG"
  else
    echo "[WARN] SMART likely not passed through by USB bridge/device." | tee -a "$LOG"
  fi

  {
    echo "# Disk Health Report"
    echo ""
    echo "- Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "- Disk: \`$(disk_label "$dev")\`"
    echo "- Mode: External"
    echo "- Status: **$health_status**"
    echo "- smartctl dtype: \`$used\`"
    [[ -n "$metrics" ]] && echo "- SMART metrics: $metrics"
    echo ""
    echo "## Evidence"
    echo "- Log: \`$LOG\`"
    [[ -n "$out_file" ]] && echo "- smartctl output: \`$out_file\`"
  } > "$REPORT"

  if [[ "$health_status" == "UNSUPPORTED" ]]; then
    cat >>"$REPORT" <<'EOF'
## Summary
SMART / health attributes cannot be retrieved from this external drive because the current USB bridge/enclosure does **not** pass through SMART commands. This is a **hardware/bridge limitation**, not a confirmed disk failure.

## Recommended Alternative Checks
1) Disk Utility → First Aid
2) Copy large files and watch for I/O errors/stalls
3) Check Console.app for repeated disconnects / I/O errors

## How to enable SMART
Use an enclosure/dock that supports SMART passthrough on macOS, or direct SATA when possible.
EOF
  fi

  echo "SUMMARY | mode=external | status=$health_status | device=$dev | dtype=$used | ${metrics:-} | report=$(basename "$REPORT")" | tee -a "$LOG"
}

if [[ "$IS_INTERNAL" == "true" ]]; then
  internal_check "$DISK_CHOSEN" "$SMARTCTL_BIN"
else
  external_check "$DISK_CHOSEN" "$SMARTCTL_BIN"
fi

cleanup_old_files "$LOG_DIR" "$RETENTION_DAYS"
cleanup_old_files "$REPORT_DIR" "$RETENTION_DAYS"

echo "[DONE] Log: $LOG" | tee -a "$LOG"
echo "[DONE] Report: $REPORT" | tee -a "$LOG"
