#!/usr/bin/env bash
set -u
set -o pipefail
Last run: 2026-01-24 21:47 backup_real rc=0

# =========================
# Load toolbox config
# =========================
CFG="${TOOLBOX_CFG:-$HOME/toolbox/conf/toolbox.conf}"

if [[ ! -f "$CFG" ]]; then
  echo "[ERROR] Missing toolbox config: $CFG"
  echo "Create it and define (optional): NETCHECK, DISK_HEALTH, BACKUP, SYNC_MODULE, REPORT_DIR, LOG_DIR"
  exit 2
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<EOF
toolbox - personal system toolbox

Config: $CFG

Modules:
  netcheck
  disk-health
  backup
  sync
  open_last_snapshot
  sync_history
  toolbox_doctor
EOF
  exit 0
fi

# shellcheck disable=SC1090
source "$CFG"

# ======================
# User-facing locations
# ======================
REPORT_DIR="${REPORT_DIR:-$HOME/toolbox/IT_Reports}"
LOG_DIR="${LOG_DIR:-$HOME/toolbox/Logs}"
mkdir -p "$REPORT_DIR" "$LOG_DIR"

# ======================
# Modules (config-first, default fallback)
# ======================
NETCHECK="$HOME/toolbox/bin/netcheck"
DISK_HEALTH="$HOME/toolbox/bin/check_disk_health"
BACKUP="$HOME/toolbox/bin/backup_rsync"
SYNC_MODULE="$HOME/toolbox/bin/sync_reports"
TOOLBOX_DOCTOR="$HOME/toolbox/bin/toolbox_doctor"
OPEN_LAST_SNAPSHOT="$HOME/toolbox/bin/open_last_snapshot"
WIFI_WATCH="$HOME/toolbox/bin/wifi_watch"
NOVEL_CRAWLER="$HOME/toolbox/bin/novel_novel_crawler"

#NOVEL_DIR="${NOVEL_DIR:-$HOME/toolbox/ops/novel}"
#NOVEL_CRAWLER="${NOVEL_CRAWLER:-$NOVEL_DIR/novel_crawler}"
#VENV="${VENV:-$NOVEL_DIR/.venv}"


find ~/toolbox/bin -type l -exec test ! -e {} \; -print

ts() { date +"%Y%m%d_%H%M%S"; }
say() { printf "\n== %s ==\n" "$*"; }
die() { echo "ERROR: $*" >&2; return 1; }


# for binaries/scripts that must be executable
check_exec() {
  local f="$1"
  [[ -e "$f" ]] || die "Not found: $f"
  [[ -x "$f" ]] || die "Not executable: $f (try: chmod +x '$f')"
}

# for scripts invoked via "bash script.sh"
check_file() {
  local f="$1"
  [[ -f "$f" ]] || die "Not found: $f"
}

open_dir() {
  local d="$1"
  mkdir -p "$d"
  open "$d" >/dev/null 2>&1 || true
}

menu() {
  echo
  echo "===== TOOLBOX-V2.0 ====="
  echo "Reports: $REPORT_DIR"
  echo "Logs:    $LOG_DIR"
  echo
  echo "1) NetCheck (LAN/WAN)     -> $NETCHECK"
  echo "2) Disk Health Check      -> $DISK_HEALTH"
  echo "3) Full backup to iMac (rsync over SSH)   -> $BACKUP"
  echo "4) Novel Crawler (Python) -> $NOVEL_CRAWLER"
  echo "5) Open report folders"
  echo "6) Sync reports + logs to iMac (SSH)   -> $SYNC_MODULE"
  echo "7) Sync history (last 10)  -> $HOME/toolbox/bin/sync_history"
  echo "8) Toolbox doctor  -> $HOME/toolbox/bin/toolbox_doctor"
  echo "9) Open Last Snapshot -> $HOME/toolbox/bin/open_last_snapshot"
  echo "10) WiFi Watch -> $HOME/toolbox/bin/wifi_watch"
  echo "0) Exit"
}

main() {
  while true; do
    menu
    read -r -p "Select: " n
    case "${n:-}" in
      1)
        check_exec "$NETCHECK"
        SAVE_DIR="$REPORT_DIR" "netcheck" "$NETCHECK"
        read -r -p "Press Enter to return to menu..." _
        ;;

      2)
        say "Disk Health Check"
        check_file "$DISK_HEALTH"

        echo "1) Internal disk0 (recommended)"
        echo "2) Scan ALL disks (internal + external)"
        echo "3) Specify DISK_ID (e.g. disk4)"
        read -r -p "Select (1-3): " sub
        
        rc=0

        case "${sub:-}" in
          1)
            # 子程序自己写 log/report，toolbox 不再二次 tee
            DISK_ID="disk0" LOG_DIR="$LOG_DIR" REPORT_DIR="$REPORT_DIR" \
              bash "$DISK_HEALTH"
            rc=$?
            ;;
          2)
            SCAN_ALL="1" LOG_DIR="$LOG_DIR" REPORT_DIR="$REPORT_DIR" \
              bash "$DISK_HEALTH"
            rc=$?
            ;;
          3)
            read -r -p "Enter DISK_ID (e.g. disk4): " did
            [[ -n "${did:-}" ]] || { echo "Cancelled."; continue; }

            DISK_ID="$did" LOG_DIR="$LOG_DIR" REPORT_DIR="$REPORT_DIR" \
              bash "$DISK_HEALTH"
            rc=$?
            ;;
          *)
            echo "Invalid selection."
            continue
            ;;
        esac

        echo
        if [[ $rc -eq 0 ]]; then
          echo "[OK] Disk Health Check completed."
        else
          echo "[WARN] Disk Health Check exited with code: $rc"
        fi

        read -r -p "Press Enter to return to menu..." _
        ;;


      3)
        say "Backup (rsync)"
        check_exec "$BACKUP"

        echo "1) Dry run (preview only)"
        echo "2) Real run (will copy/delete according to config)"
        read -r -p "Select (1-2): " sub

        case "${sub:-}" in
          1)
            echo
            echo "[INFO] Running backup in DRY-RUN mode..."
            echo "[CMD]  zsh \"$BACKUP\" --dry-run"
            echo
            set +e
            zsh "$BACKUP" --dry-run
            rc=$?
            set -e
            echo
            echo "[INFO] backup_rsync exited with code: $rc"
            ;;

          2)
            echo
            read -r -p "Type YES to start REAL backup: " ans
            if [[ "$ans" != "YES" ]]; then
              echo "Cancelled."
              read -r -p "Press Enter to return to menu..." _
              
            fi

            echo
            echo "[INFO] Running backup in REAL mode..."
            echo "[CMD]  zsh \"$BACKUP\""
            echo
            set +e
            zsh "$BACKUP"
            rc=$?
            set -e
            echo
            echo "[INFO] backup_rsync exited with code: $rc"
            ;;
          *)
            echo "Invalid selection."
            ;;
        esac

        read -r -p "Press Enter to return to menu..." _
        ;;

      4)
       say "Novel Crawler"

       [[ -x "$NOVEL_CRAWLER" ]] || die "Novel crawler not executable: $NOVEL_CRAWLER"

       # ---- Inputs ----
       DEFAULT_TOC_URL="${DEFAULT_TOC_URL:-https://www.bidutuijian.com/books/yztpingsanguo/000.html}"
       read -r -p "TOC URL [default: $DEFAULT_TOC_URL]: " toc_url
       toc_url="${toc_url:-$DEFAULT_TOC_URL}"
       [[ -n "$toc_url" ]] || { echo "[ERROR] toc_url is required."; read -r -p "Press Enter..." _; continue; }

       DEFAULT_OUT="${OUT_DIR:-$HOME/toolbox/ops/novel/novel_out}"
       read -r -p "OUT dir (--out) [default: $DEFAULT_OUT]: " out_dir
       out_dir="${out_dir:-$DEFAULT_OUT}"
       mkdir -p "$out_dir"

       # start/end 可选（回车=不传该参数）
       read -r -p "Start chapter (--start) [default: 1]: " start_ch
       start_ch="${start_ch:-1}"

       read -r -p "End chapter   (--end)   [default: 99999]: " end_ch
        end_ch="${end_ch:99999}"
       # merge 可选：回车=不合并；输入名字= --merge <name>
       read -r -p "Merge name (--merge) [blank=no merge name]: " merge_name

       # epub yes/no（默认 no）
       read -r -p "Generate EPUB? (--epub) [yes/no, default: no]: " epub_ans
       epub_ans="${epub_ans:-no}"

       # ---- Build command safely ----
       cmd=( "$NOVEL_CRAWLER" "$toc_url" --out "$out_dir" )

       # 只在用户输入时才追加
       [[ -n "${start_ch:-}" ]] && cmd+=( --start "$start_ch" )
       [[ -n "${end_ch:-}"   ]] && cmd+=( --end   "$end_ch" )

       [[ -n "${merge_name:-}" ]] && cmd+=( --merge "$merge_name" )

       case "$epub_ans" in
       y|Y|yes|YES) cmd+=( --epub ) ;;
       n|N|no|NO)   : ;;
       *) echo "[ERROR] invalid epub option: $epub_ans (use yes/no)"; read -r -p "Press Enter..." _; continue ;;
       esac

       # ---- Run (no tee, preserve TTY interaction) ----
       LOG="$out_dir/novel_crawler_$(date +%F_%H%M%S).log"
       echo "[INFO] Logging to: $LOG"
       env PYTHONUNBUFFERED=1 script -q "$LOG" "${cmd[@]}"


       read -r -p "Press Enter to return to menu..." _
        ;;

      5)
        say "Open folders"
        open_dir "$REPORT_DIR"
        open_dir "$LOG_DIR"
        read -r -p "Press Enter to return..." _
        ;;

      6)
        say "Sync reports + logs to iMac (SSH)"
        check_file "$SYNC_MODULE"

        echo "1) Normal run"
        echo "2) Debug run (prints variables)"
        read -r -p "Select (1-2): " sub
        case "${sub:-}" in
          2) DEBUG=1 bash "$SYNC_MODULE" ;;
          *) bash "$SYNC_MODULE" ;;
        esac

        read -r -p "Press Enter to return to menu..." _
        ;;

      7)
        say "Sync History"
        read -r -p "Show last N records [default 10]: " n
        n="${n:-10}"
        "$HOME/toolbox/bin/sync_history" "$n"
        read -r -p "Press Enter to return to menu..." _
        ;;

      8)
        say "Toolbox Doctor"

        if command -v toolbox_doctor >/dev/null 2>&1; then
          toolbox_doctor
        elif [[ -n "${TOOLBOX_DOCTOR:-}" && -x "$TOOLBOX_DOCTOR" ]]; then
          "$TOOLBOX_DOCTOR"
        else
          echo "[ERROR] toolbox_doctor not found in PATH, and TOOLBOX_DOCTOR not set"
          echo "Tip: make sure ~/toolbox/bin is in PATH and toolbox_doctor is executable."
        fi

        read -r -p "Press Enter to return to menu..." _
        ;;

      9)
        "$OPEN_LAST_SNAPSHOT"
        read -r -p "Press Enter to return to menu..." _
        ;;

      10) 
        echo "== WiFi Watch =="
        echo "[INFO] Ctrl-C will stop WiFi Watch and return to toolbox menu."
        echo
        # 1) 先前台 sudo 预热（关键：避免后台 sudo 读不到密码）
        if ! sudo -v; then
          echo "[ERROR] sudo auth failed."
          read -r -p "Press Enter to return to menu..." _
          break
        fi

        set +e
        set -m   # ✅ 开启 job control（关键：让后台任务变成独立进程组）

        #2) 后台启动 （注意：pid 是 sudo 的pid）
        sudo "$WIFI_WATCH" 8.8.8.8 2 100 on &
        pid=$!

        #3） 在 macOS 下，用 ps 拿到该任务的进程组 ID（有了 set -m，一般 pgid==pid），用于 ctrl c 一次性杀掉整个组
        pgid="$(ps -o pgid= "$pid" 2>/dev/null | tr -d ' ')"
        
        #如果担心脚本异常退出导致 watch 残留，加一段 EXIT 清理：
        cleanup_watch() {
          [[ -n "${pgid:-}" ]] && kill -TERM -- -"$pgid" 2>/dev/null || true
        }
        trap cleanup_watch EXIT

        #4）ctrl c处理：杀掉整个进程组（包括 sudo + wifi watch + 子进程）
        trap 'echo; echo "[INFO] Stopping WiFi Watch..."; kill -INT -- -"$pgid" 2>/dev/null' INT

        #5）等待结束
        wait "$pid"
        rc=$?
        #6）恢复 ctrl c默认行为
        trap - INT
        set +m   # ✅ 关闭 job control
        set -e

        echo
        if [[ $rc -eq 130 ]]; then
          echo "[OK] WiFi Watch stopped (Ctrl-C). Returning to toolbox..."
        else
          echo "[INFO] WiFi Watch exited with code: $rc"
        fi

        read -r -p "Press Enter to return to menu..." _
        ;;

      0) exit 0 ;;
      *) echo "Invalid choice." ;;
    esac
  done
}

main
