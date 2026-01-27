#!/usr/bin/env bash
set -euo pipefail

VERSION="2.0"

ts() { date +"%Y%m%d_%H%M%S"; }
say() { printf "\n=== %s ===\n" "$*"; }

copy_clipboard() {
  local s="${1:-}"
  command -v pbcopy >/dev/null 2>&1 || return 0
  [[ -n "$s" ]] || return 0
  printf "%s" "$s" | pbcopy
}

# ====== tunables (env overrides) ======
COUNT_GW="${COUNT_GW:-10}"
COUNT_WAN="${COUNT_WAN:-10}"
WAN_IP="${WAN_IP:-1.1.1.1}"
WAN_DNS="${WAN_DNS:-google.com}"

# Thresholds for grading (ms)
# LAN is stricter because it's your gateway.
LAN_EX_AVG=5    ; LAN_EX_SD=2   ; LAN_EX_MAX=20
LAN_GO_AVG=10   ; LAN_GO_SD=5   ; LAN_GO_MAX=40
LAN_OK_AVG=20   ; LAN_OK_SD=10  ; LAN_OK_MAX=80
LAN_WR_AVG=40   ; LAN_WR_SD=20  ; LAN_WR_MAX=150

WAN_EX_AVG=15   ; WAN_EX_SD=5   ; WAN_EX_MAX=40
WAN_GO_AVG=30   ; WAN_GO_SD=10  ; WAN_GO_MAX=80
WAN_OK_AVG=50   ; WAN_OK_SD=20  ; WAN_OK_MAX=150
WAN_WR_AVG=80   ; WAN_WR_SD=40  ; WAN_WR_MAX=300

# ====== helpers ======
gt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}'; }
ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>=b)}'; }

get_gw() {
  route -n get default 2>/dev/null | awk '/gateway:/{print $2}' | head -n1 || true
}

active_if() {
  # Detect active interface for default route
  route -n get default 2>/dev/null | awk '/interface:/{print $2}' | head -n1 || true
}

if_kind() {
  # Map interface to kind (Wi-Fi/Ethernet/Other)
  local iface="$1"
  networksetup -listallhardwareports 2>/dev/null | awk -v dev="$iface" '
    $0 ~ /^Hardware Port:/ {port=$0}
    $0 ~ /^Device:/ {d=$2}
    d==dev {print port; exit}
  ' | sed 's/^Hardware Port: *//'
}

wifi_info() {
  # Try airport first, fallback to system_profiler.
  local airport="/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
  if [[ -x "$airport" ]]; then
    "$airport" -I 2>/dev/null | egrep " SSID| BSSID| channel| agrCtlRSSI| noise| lastTxRate" || true
  else
    system_profiler SPAirPortDataType 2>/dev/null \
      | egrep -i "Current Network Information|SSID|Channel|Signal / Noise|Transmit Rate|PHY Mode" \
      | head -n 30 || true
  fi
}

ping_summary_line() {
  local host="$1" count="$2"
  ping -c "$count" "$host" 2>/dev/null | awk '/round-trip/ {line=$0} END{print line}'
}

parse_rtt() {
  # Output: avg max stddev (numbers only)
  local line="$1"
  awk -v s="$line" '
    BEGIN {
      n = split(s, a, "=")
      rhs = a[n]
      gsub(/^[ \t]+|[ \t]+$/, "", rhs)
      gsub(/ ms$/, "", rhs)
      split(rhs, b, "/")
      print b[2], b[3], b[4]
    }'
}

grade_lan() {
  local avg="$1" mx="$2" sd="$3"
  if ! gt "$avg" "$LAN_EX_AVG" && ! gt "$sd" "$LAN_EX_SD" && ! gt "$mx" "$LAN_EX_MAX"; then echo "Excellent"; return; fi
  if ! gt "$avg" "$LAN_GO_AVG" && ! gt "$sd" "$LAN_GO_SD" && ! gt "$mx" "$LAN_GO_MAX"; then echo "Good"; return; fi
  if ! gt "$avg" "$LAN_OK_AVG" && ! gt "$sd" "$LAN_OK_SD" && ! gt "$mx" "$LAN_OK_MAX"; then echo "OK"; return; fi
  if ! gt "$avg" "$LAN_WR_AVG" && ! gt "$sd" "$LAN_WR_SD" && ! gt "$mx" "$LAN_WR_MAX"; then echo "Warning"; return; fi
  echo "Poor"
}

grade_wan() {
  local avg="$1" mx="$2" sd="$3"
  if ! gt "$avg" "$WAN_EX_AVG" && ! gt "$sd" "$WAN_EX_SD" && ! gt "$mx" "$WAN_EX_MAX"; then echo "Excellent"; return; fi
  if ! gt "$avg" "$WAN_GO_AVG" && ! gt "$sd" "$WAN_GO_SD" && ! gt "$mx" "$WAN_GO_MAX"; then echo "Good"; return; fi
  if ! gt "$avg" "$WAN_OK_AVG" && ! gt "$sd" "$WAN_OK_SD" && ! gt "$mx" "$WAN_OK_MAX"; then echo "OK"; return; fi
  if ! gt "$avg" "$WAN_WR_AVG" && ! gt "$sd" "$WAN_WR_SD" && ! gt "$mx" "$WAN_WR_MAX"; then echo "Warning"; return; fi
  echo "Poor"
}

print_block() {
  local label="$1" host="$2" count="$3"
  local line avg mx sd
  line="$(ping_summary_line "$host" "$count")"
  echo "[$label] ping -c $count $host"
  echo "$line"
  read -r avg mx sd < <(parse_rtt "$line")
  echo "Parsed: avg=${avg}ms  max=${mx}ms  stddev=${sd}ms"
  echo "$avg $mx $sd"
}

# ====== logging wrapper ======
RUN_ID="$(date '+%Y%m%d_%H%M%S')"
LOG_DIR="$HOME/toolbox/Logs"
LOG="${LOG_DIR}/netcheck_${RUN_ID}.log"
mkdir -p "$LOG_DIR" 2>/dev/null || true

# Mirror all stdout/stderr to log file (and keep showing on screen)
exec > >(tee -a "$LOG") 2>&1

# ====== main ======
echo "=== Netcheck (macOS) v$VERSION ==="
echo "Time: $(date)"

GW="$(get_gw)"
IFACE="$(active_if)"
KIND="$(if_kind "${IFACE:-}")"
[[ -z "${KIND}" ]] && KIND="Unknown"

echo "Default interface: ${IFACE:-unknown} (${KIND})"
echo "Gateway: ${GW:-unknown}"

say "Wi-Fi quick view"
wifi_info || true
echo ""

if [[ -z "${GW}" ]]; then
  echo "[ERROR] Could not detect default gateway."
  echo "Log saved: $LOG"
  copy_clipboard "$LOG"
  echo "Copied log path to clipboard."
  exit 1
fi

# If on Wi-Fi, keep your detailed block too (optional)
#if [[ "$KIND" == "Wi-Fi" || "$KIND" == "WiFi" || "$KIND" == "AirPort" ]]; then
#  echo "[Wi-Fi details]"
#  wifi_info
#  echo ""
#fi

# Collect stats
LAN_STATS="$(print_block "LAN (Gateway)" "$GW" "$COUNT_GW")"
LAN_AVG="$(echo "$LAN_STATS" | tail -n1 | awk '{print $1}')"
LAN_MAX="$(echo "$LAN_STATS" | tail -n1 | awk '{print $2}')"
LAN_SD="$( echo "$LAN_STATS" | tail -n1 | awk '{print $3}')"
echo ""

WAN1_STATS="$(print_block "WAN (1.1.1.1)" "$WAN_IP" "$COUNT_WAN")"
WAN1_AVG="$(echo "$WAN1_STATS" | tail -n1 | awk '{print $1}')"
WAN1_MAX="$(echo "$WAN1_STATS" | tail -n1 | awk '{print $2}')"
WAN1_SD="$( echo "$WAN1_STATS" | tail -n1 | awk '{print $3}')"
echo ""

DNS_STATS="$(print_block "WAN (DNS name)" "$WAN_DNS" "$COUNT_WAN")"
DNS_AVG="$(echo "$DNS_STATS" | tail -n1 | awk '{print $1}')"
DNS_MAX="$(echo "$DNS_STATS" | tail -n1 | awk '{print $2}')"
DNS_SD="$( echo "$DNS_STATS" | tail -n1 | awk '{print $3}')"
echo ""

LAN_GRADE="$(grade_lan "$LAN_AVG" "$LAN_MAX" "$LAN_SD")"
WAN_GRADE="$(grade_wan "$WAN1_AVG" "$WAN1_MAX" "$WAN1_SD")"
DNS_GRADE="$(grade_wan "$DNS_AVG" "$DNS_MAX" "$DNS_SD")"

echo "=== Grades ==="
echo "LAN (Gateway): $LAN_GRADE"
echo "WAN ($WAN_IP): $WAN_GRADE"
echo "WAN ($WAN_DNS): $DNS_GRADE"
echo ""

echo "=== Quick diagnosis ==="
LAN_BAD=0; WAN_BAD=0; DNS_BAD=0
if [[ "$LAN_GRADE" == "Warning" || "$LAN_GRADE" == "Poor" ]]; then LAN_BAD=1; fi
if [[ "$WAN_GRADE" == "Warning" || "$WAN_GRADE" == "Poor" ]]; then WAN_BAD=1; fi
if [[ "$DNS_GRADE" == "Warning" || "$DNS_GRADE" == "Poor" ]]; then DNS_BAD=1; fi

if [[ "$LAN_BAD" -eq 1 && "$WAN_BAD" -eq 0 ]]; then
  echo "Likely LOCAL issue: gateway jitter/latency is high."
  echo "Actions: move closer, reduce Bluetooth headset usage, avoid USB3 hubs near MacBook, or use Ethernet."
elif [[ "$LAN_BAD" -eq 0 && "$WAN_BAD" -eq 1 ]]; then
  echo "Likely WAN/ISP issue: internet jitter/latency is high while LAN is OK."
  echo "Actions: test later, try another network, contact ISP if persistent."
elif [[ "$LAN_BAD" -eq 1 && "$WAN_BAD" -eq 1 ]]; then
  echo "Both LAN and WAN look unstable."
  echo "Actions: start with local Wi-Fi stability first, then re-test WAN."
else
  echo "Looks OK. LAN + WAN stable enough for normal use."
fi

if [[ "$LAN_BAD" -eq 0 && "$WAN_BAD" -eq 0 && "$DNS_BAD" -eq 1 ]]; then
  echo ""
  echo "DNS name ping looks worse than IP ping → possible DNS/route differences."
  echo "Actions: try different DNS (e.g., 1.1.1.1 or 8.8.8.8) if you have permission."
fi

echo ""
echo "Log saved: $LOG"
copy_clipboard "$LOG"
echo "Copied log path to clipboard."