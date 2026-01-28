#!/usr/bin/env bash
set -euo pipefail
CFG="${TOOLBOX_CFG:-$HOME/toolbox/conf/toolbox_F.conf}"

die(){ echo "[ERROR] $*" >&2; exit 1; }
say(){ printf "\n== %s ==\n" "$*"; }

[[ -f "$CFG" ]] || die "Missing config: $CFG"
# shellcheck disable=SC1090
source "$CFG"

REPORT_DIR="${REPORT_DIR:-$HOME/toolbox/IT-Reports}"
LOG_DIR="${LOG_DIR:-$HOME/toolbox/Logs}"
mkdir -p "$REPORT_DIR" "$LOG_DIR"

# 固定模块路径（只读类）
NETCHECK="${NETCHECK:-$HOME/toolbox/bin/netcheck}"
DISK_HEALTH="${DISK_HEALTH:-$HOME/toolbox/bin/check_disk_health}"
TOOLBOX_DOCTOR="${TOOLBOX_DOCTOR:-$HOME/toolbox/bin/toolbox_doctor_F}"

ts(){ date +"%Y%m%d_%H%M%S"; }

run_and_log() {
  local name="$1"; shift
  local logfile="$LOG_DIR/${name}_$(ts).log"
  "$@" 2>&1 | tee "$logfile"
  echo "Log saved: $logfile"
}

check_exec() {
  local f="$1"
  [[ -e "$f" ]] || die "Not found: $f"
  [[ -x "$f" ]] || die "Not executable: $f (try: chmod +x '$f')"
}

open_dir() {
  local d="$1"
  mkdir -p "$d"
  open "$d" >/dev/null 2>&1 || true
}

menu() {
  echo
  echo "===== TOOLBOX-F (Field / Safe) ====="
  echo “Safe mode: no delete / no sync / no backup operations included.”
  echo "Profile: ${PROFILE:-F}"
  echo "Reports: $REPORT_DIR"
  echo "Logs:    $LOG_DIR"
  echo
  echo "1) NetCheck (LAN/WAN)"
  echo "2) Disk Health Check (SMART / diskutil)"
  echo "3) Open report folders"
  echo "4) Toolbox doctor"
  echo "0) Exit"
}

main() {
  while true; do
    menu
    read -r -p "Select: " n
    case "${n:-}" in
      1)
        check_exec "$NETCHECK"
        SAVE_DIR="$REPORT_DIR" run_and_log "netcheck" "$NETCHECK"
        read -r -p "Press Enter to return..." _
        ;;

      2)
        say "Disk Health Check"
        check_exec "$DISK_HEALTH"
        echo "1) Internal disk0 (recommended)"
        echo "2) Scan ALL disks (internal + external)"
        read -r -p "Select (1-2): " sub
        case "${sub:-}" in
          1)
            run_and_log "disk_health" env DISK_ID="disk0" LOG_DIR="$LOG_DIR" REPORT_DIR="$REPORT_DIR" bash "$DISK_HEALTH"
            ;;
          2)
            run_and_log "disk_health_all" env SCAN_ALL="1" LOG_DIR="$LOG_DIR" REPORT_DIR="$REPORT_DIR" bash "$DISK_HEALTH"
            ;;
          *)
            echo "Invalid selection."
            continue
            ;;
        esac
        read -r -p "Press Enter to return..." _
        ;;

      3)
        say "Open folders"
        open_dir "$REPORT_DIR"
        open_dir "$LOG_DIR"
        read -r -p "Press Enter to return..." _
        ;;

      4)
        toolbox_doctor_F
        read -r -p "Press Enter to return..." _
        ;;

      0) exit 0 ;;
      *) echo "Invalid choice." ;;
    esac
  done
}

main
