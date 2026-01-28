#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# macOS Wi-Fi 深度监控工具（最终覆盖版 + 参数校验）
# ==========================================================
# 用法：
#   ./wifi_watch.sh                              # 默认 8.8.8.8 每2秒 阈值100ms 记录日志
#   ./wifi_watch.sh 192.168.1.1 1 50 on          # ping 网关，每1秒，>50ms 报警，日志开
#   ./wifi_watch.sh 8.8.8.8 2 100 off            # 不写日志
#
# 参数顺序：
#   $1 TARGET        目标IP/域名
#   $2 INTERVAL      刷新间隔（秒，整数）
#   $3 HIGH_LAT_MS   高延迟阈值（ms，整数）
#   $4 LOG_MODE      on/off
# ==========================================================

usage() {
  cat <<'EOF'
Usage:
  ./wifi_watch.sh [TARGET] [INTERVAL] [HIGH_LAT_MS] [LOG_MODE]

Examples:
  ./wifi_watch.sh
  ./wifi_watch.sh 192.168.1.1 1 50 on
  ./wifi_watch.sh 8.8.8.8 2 100 off

Args:
  TARGET        ping 目标（如 192.168.1.1 或 8.8.8.8），默认 8.8.8.8
  INTERVAL      刷新间隔（秒，整数），默认 2
  HIGH_LAT_MS   高延迟阈值（ms，整数），默认 100
  LOG_MODE      on/off，默认 on
EOF
}

fatal() { echo "[FATAL] $*" >&2; exit 1; }
warn()  { echo "[WARN]  $*" >&2; }

is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
is_onoff(){ [[ "${1:-}" == "on" || "${1:-}" == "off" ]]; }

# ---------- Defaults ----------
TARGET="${1:-8.8.8.8}"
INTERVAL="${2:-2}"
HIGH_LAT_MS="${3:-100}"
LOG_MODE="${4:-on}"
# ----------------------------

# ---------- Validation ----------
# 支持 -h/--help
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage; exit 0
fi

# 如果用户提供了 $2/$3/$4，必须校验格式，避免传错位
if [[ $# -ge 2 ]] && ! is_int "$INTERVAL"; then
  usage
  fatal "INTERVAL 必须是整数秒。你输入的是：'$INTERVAL'（你是不是把 50/on 写错位置了？正确例子：./wifi_watch.sh 192.168.1.1 1 50 on）"
fi

if [[ $# -ge 3 ]] && ! is_int "$HIGH_LAT_MS"; then
  usage
  fatal "HIGH_LAT_MS 必须是整数毫秒。你输入的是：'$HIGH_LAT_MS'（正确例子：./wifi_watch.sh 192.168.1.1 1 50 on）"
fi

if [[ $# -ge 4 ]] && ! is_onoff "$LOG_MODE"; then
  usage
  fatal "LOG_MODE 只能是 on 或 off。你输入的是：'$LOG_MODE'"
fi

# 合理范围提示（不强制）
if is_int "$INTERVAL" && (( INTERVAL < 1 )); then
  fatal "INTERVAL 不能小于 1 秒（你输入 $INTERVAL）"
fi
if is_int "$HIGH_LAT_MS" && (( HIGH_LAT_MS < 1 )); then
  fatal "HIGH_LAT_MS 不能小于 1 ms（你输入 $HIGH_LAT_MS）"
fi
# -------------------------------

# ---------- Setup ----------
#1.加载配置文件
#固定路径加载
ENV_FILE="$HOME/toolbox/conf/net.env"
if [[ -f "$ENV_FILE" ]]; then
  echo "[INFO] Loading env file: $ENV_FILE"
  source "$ENV_FILE"
else
  echo "[WARN] Env file not found: $ENV_FILE (proceeding with defaults)"
  echo "[INFO] Using defaults for LOG_ROOT"
fi
#2.使用配置中的变量
LOG_ROOT="${LOG_ROOT:-$LOG_DIR/WiFiWatch}"
#或者直接使用
#LOG_ROOT="$LOG_DIR/WiFiWatch"

#3. 工具路径
WDUTIL="/usr/bin/wdutil"
PING="/sbin/ping"
# 4.创建日志目录
mkdir -p "$LOG_ROOT"

# ---------------------------
now_time() { date "+%H:%M:%S"; }
today() { date "+%Y-%m-%d"; }

# 解析 "Key : Value"；允许 Key 左侧空格；Key 前缀匹配（兼容 RSSI (dBm)）
kv_get() {
  local key="$1"
  awk -F': *' -v k="$key" '
    BEGIN{IGNORECASE=1}
    {
      gsub(/^[ \t]+/,"",$1)
      if ($1 ~ ("^"k)) { print $2; exit }
    }
  '
}
num_only() { sed -E 's/[^0-9.-]+//g'; }

[[ -x "$WDUTIL" ]] || fatal "找不到 wdutil：$WDUTIL（macOS 版本可能不支持）"
[[ -x "$PING" ]]   || fatal "找不到 ping：$PING"
command -v sudo >/dev/null 2>&1 || fatal "未找到 sudo（无法运行 sudo wdutil info）"

# 你的系统必须 sudo 才能用 wdutil info
sudo -v || fatal "sudo 验证失败（无法读取 Wi-Fi 指标）"
( while true; do sudo -n true 2>/dev/null || true; sleep 30; done ) &
KEEPALIVE_PID=$!
trap 'kill ${KEEPALIVE_PID:-0} 2>/dev/null || true' EXIT

# Logging setup
if [[ "$LOG_MODE" == "on" ]]; then
  mkdir -p "$LOG_ROOT"
  LOG_FILE="$LOG_ROOT/$(today)_wifi_watch.log"
  CSV_FILE="$LOG_ROOT/$(today)_wifi_watch.csv"
  if [[ ! -f "$CSV_FILE" ]]; then
    echo "date,time,target,ssid,channel,rssi_dbm,noise_dbm,snr_db,latency_ms,status" >> "$CSV_FILE"
  fi
fi

# ---------------------------
# Logging init (robust)
# ---------------------------
LOG_DIR="${LOG_DIR:-$HOME/Logs/WiFiWatch}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/${DATE}_wifi_watch.log}"

ensure_log_writable() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true

  # 试探能不能创建/写入
  if ! ( : >> "$LOG_FILE" ) 2>/dev/null; then
    # fallback 到 macOS 更推荐的位置
    LOG_DIR="$HOME/Library/Logs/WiFiWatch"
    LOG_FILE="$LOG_DIR/${DATE}_wifi_watch.log"
    mkdir -p "$LOG_DIR" 2>/dev/null || true

    if ! ( : >> "$LOG_FILE" ) 2>/dev/null; then
      echo "[WARN] LOG disabled: cannot write to $LOG_FILE" >&2
      LOG_MODE="off"
      return 1
    fi
  fi
  return 0
}

# 只要 LOG_MODE=on 才初始化
if [[ "${LOG_MODE:-off}" == "on" ]]; then
  ensure_log_writable || true
fi

echo "=============================================================="
echo "      macOS Wi-Fi 深度监控工具（最终版 + 参数校验）"
echo "=============================================================="
echo "Target=$TARGET | Interval=${INTERVAL}s | HighLatency>${HIGH_LAT_MS}ms | Log=$LOG_MODE"
echo "LogDir=$LOG_ROOT"
echo "Time     | SSID [CH]                 | RSSI/Noise  SNR | Latency    | Status"
echo "---------+----------------------------+-----------------+------------+--------"

while true; do
  TIME="$(now_time)"
  DATE="$(today)"

  WIFI_INFO="$(sudo -n "$WDUTIL" info 2>/dev/null || true)"

  if [[ -z "$WIFI_INFO" ]]; then
    SSID="未知"; CHANNEL="N/A"
    RSSI_DISP="N/A"; NOISE_DISP="N/A"; SNR="N/A"
    WIFI_NOTE="wdutil无输出（可能未连接Wi-Fi/系统限制）"
    RSSI=""; NOISE=""
  else
    SSID="$(printf "%s" "$WIFI_INFO" | kv_get "SSID" || true)"
    CHANNEL="$(printf "%s" "$WIFI_INFO" | kv_get "Channel" || true)"
    RSSI_RAW="$(printf "%s" "$WIFI_INFO" | kv_get "RSSI" || true)"
    NOISE_RAW="$(printf "%s" "$WIFI_INFO" | kv_get "Noise" || true)"

    RSSI="$(printf "%s" "${RSSI_RAW:-}" | num_only)"
    NOISE="$(printf "%s" "${NOISE_RAW:-}" | num_only)"

    SSID="${SSID:-未知}"
    CHANNEL="${CHANNEL:-N/A}"

    RSSI_DISP="${RSSI_RAW:-N/A}"
    NOISE_DISP="${NOISE_RAW:-N/A}"
    SNR="N/A"
    WIFI_NOTE=""

    if [[ -n "${RSSI:-}" && -n "${NOISE:-}" ]]; then
      RSSI_DISP="${RSSI}dBm"
      NOISE_DISP="${NOISE}dBm"
      if [[ "$RSSI" =~ ^-?[0-9]+$ && "$NOISE" =~ ^-?[0-9]+$ ]]; then
        SNR=$(( RSSI - NOISE ))
      fi
    fi
  fi

  PING_RES="$("$PING" -c 1 -W 1000 "$TARGET" 2>/dev/null || true)"
  LATENCY="$(printf "%s" "$PING_RES" | sed -n 's/.*time[=<]\([0-9.]*\) *ms.*/\1/p' | head -n 1)"

  STATUS="❌ 丢包/超时"
  LATENCY_DISP="timeout"
  LAT_NUM=""

  if [[ -n "${LATENCY:-}" && "$LATENCY" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    LATENCY_DISP="${LATENCY} ms"
    LAT_NUM="$LATENCY"
    if awk "BEGIN {exit !($LATENCY > $HIGH_LAT_MS)}"; then
      STATUS="⚠️ 高延迟"
    else
      STATUS="✅ 稳定"
    fi
  fi

  printf "%-8s | %-26s [%-6s] | %-10s %-10s %4s | %-10s | %s\n" \
    "$TIME" "$SSID" "$CHANNEL" "$RSSI_DISP" "$NOISE_DISP" "$SNR" "$LATENCY_DISP" "$STATUS"

  if [[ "$LOG_MODE" == "on" ]]; then
    echo "$DATE $TIME | target=$TARGET | ssid='${SSID}' ch='${CHANNEL}' rssi='${RSSI_DISP}' noise='${NOISE_DISP}' snr='${SNR}' latency='${LATENCY_DISP}' status='$STATUS' ${WIFI_NOTE:+| note=$WIFI_NOTE}" >> "$LOG_FILE"

    RSSI_NUM=""; NOISE_NUM=""
    [[ "${RSSI:-}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && RSSI_NUM="$RSSI"
    [[ "${NOISE:-}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && NOISE_NUM="$NOISE"

    echo "$DATE,$TIME,$TARGET,\"$SSID\",\"$CHANNEL\",$RSSI_NUM,$NOISE_NUM,$SNR,$LAT_NUM,\"$STATUS\"" >> "$CSV_FILE"
  fi

  sleep "$INTERVAL"
done
