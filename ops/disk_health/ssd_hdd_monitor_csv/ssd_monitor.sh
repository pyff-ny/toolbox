#!/bin/bash
set -euo pipefail

# ====== 配置 ======
INTERVAL="${1:-60}"                # 默认每 60 秒刷新一次
LOG_FILE="${LOG_FILE:-$HOME/ssd_monitor.log}"
ALERT_TEMP_C="${ALERT_TEMP_C:-70}" # 温度超过多少度报警（可改）
ONCE="${ONCE:-0}"                  # ONCE=1 只跑一次

# ====== 工具检测 ======
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# ====== 找到系统盘“整盘”标识（disk0 这种） ======
get_system_whole_disk() {
  # root volume -> diskXsY -> Part of Whole -> diskX
  local part whole
  part="$(diskutil info / 2>/dev/null | awk -F': *' '/Device Identifier/ {print $2; exit}')"
  if [[ -z "${part:-}" ]]; then
    echo "UNKNOWN"
    return
  fi
  whole="$(diskutil info "$part" 2>/dev/null | awk -F': *' '/Part of Whole/ {print $2; exit}')"
  echo "${whole:-UNKNOWN}"
}

# ====== diskutil 的 SMART 状态（Verified/Failing/Not Supported） ======
get_diskutil_smart_status() {
  local whole="$1"
  diskutil info "$whole" 2>/dev/null | awk -F': *' '/SMART Status/ {print $2; exit}' || true
}

# ====== 用 smartctl 读 NVMe SMART（最好信息最全） ======
collect_smartctl_nvme() {
  local whole="$1"
  local dev="/dev/$whole"
  local out
  out="$(smartctl -a -d nvme "$dev" 2>/dev/null || true)"

  # 温度（常见字段：Temperature: 35 Celsius）
  local temp
  temp="$(echo "$out" | awk '/Temperature:/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}')"

  # NVMe 磨损/健康（常见字段：Percentage Used: 1%）
  local pct_used
  pct_used="$(echo "$out" | awk -F': *' '/Percentage Used:/ {gsub(/%/,"",$2); print $2; exit}' | awk '{print $1}')"

  # 写入量（常见字段：Data Units Written: ... [x.xx TB]）
  local written_tb
  written_tb="$(echo "$out" | sed -n 's/.*Data Units Written:.*\[\(.*\)\].*/\1/p' | head -n1)"

  # 通电时间（Power On Hours）
  local poh
  poh="$(echo "$out" | awk -F': *' '/Power On Hours:/ {print $2; exit}' | awk '{print $1}')"

  # 开关机/上电次数（Power Cycles）
  local pcycles
  pcycles="$(echo "$out" | awk -F': *' '/Power Cycles:/ {print $2; exit}' | awk '{print $1}')"

  echo "$temp|$pct_used|$written_tb|$poh|$pcycles"
}

# ====== 弹 macOS 通知（可选） ======
notify() {
  local title="$1"
  local msg="$2"
  if have_cmd osascript; then
    osascript -e "display notification \"${msg}\" with title \"${title}\"" >/dev/null 2>&1 || true
  fi
}

# ====== 主逻辑：采集 + 输出 ======
print_header_once() {
  echo "timestamp,disk,smart_status,temp_c,percent_used,data_written,power_on_hours,power_cycles" | tee -a "$LOG_FILE"
}

run_once() {
  local whole smart_status temp pct_used written poh pcycles
  whole="$(get_system_whole_disk)"
  smart_status="$(get_diskutil_smart_status "$whole")"
  smart_status="${smart_status:-UNKNOWN}"

  temp=""
  pct_used=""
  written=""
  poh=""
  pcycles=""

  if have_cmd smartctl && [[ "$whole" != "UNKNOWN" ]]; then
    IFS='|' read -r temp pct_used written poh pcycles < <(collect_smartctl_nvme "$whole")
  fi

  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "${ts},${whole},${smart_status},${temp},${pct_used},${written},${poh},${pcycles}" | tee -a "$LOG_FILE"

  # 温度报警（如果能读到 temp）
  if [[ -n "${temp:-}" ]] && [[ "$temp" =~ ^[0-9]+$ ]]; then
    if (( temp >= ALERT_TEMP_C )); then
      notify "SSD 温度警报" "当前 ${temp}°C（阈值 ${ALERT_TEMP_C}°C），请检查散热/负载。"
    fi
  fi
}

# ====== 入口 ======
# 建议首次运行前先写表头（如果文件不存在）
if [[ ! -f "$LOG_FILE" ]]; then
  print_header_once
fi

# 运行一次 or 循环
if [[ "$ONCE" == "1" ]]; then
  run_once
  exit 0
fi

while true; do
  run_once
  sleep "$INTERVAL"
done
