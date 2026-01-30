#!/usr/bin/env bash
# backup_menu.sh - 备份脚本专用交互式菜单

set -euo pipefail
TOOLBOX_DIR="${TOOLBOX_DIR:-$HOME/toolbox}"
LOG_DIR="${LOG_DIR:-$TOOLBOX_DIR/_out/Logs}"
BACKUP_SCRIPT="${TOOLBOX_DIR}/scripts/backup/rsync_backup_final.sh"

source "$TOOLBOX_DIR/scripts/_lib/load_conf.sh"
load_module_conf "ssh_sync" \
    "DEST_HOST" "DEST_USER" || exit $?

CONF_PATH="${TOOLBOX_CONF_USED:-}"

menu_backup() {
  cat <<'EOF'
╔═══════════════════════════════════════╗
║     Backup Script Interactive Menu   ║
╚═══════════════════════════════════════╝

1) Run Backup (Real)
2) Run Dry-Run (Test)
3) View All Logs
4) Edit Config
5) Test SSH Connection
6) Schedule Daily Backup
7) Exit
Enter choice [1-7]: 
EOF
}

while true; do
  menu_backup
  read -r choice
  
  case "$choice" in
    1)
      echo "▶ Starting REAL backup..."
      "$BACKUP_SCRIPT"
      echo "Press Enter to continue..."
      read -r
      ;;
    2)
      echo "▶ Starting DRY-RUN (test mode)..."
      "$BACKUP_SCRIPT" --dry-run
      echo "Press Enter to continue..."
      read -r
      ;;
   
    3)
      echo "▶ Available logs:"
      ls -lht "$LOG_DIR"/rsync_backup_*.log 2>/dev/null | head -n 20
      echo "Press Enter to continue..."
      read -r
      ;;
    4)
      ${EDITOR:-nano} "$TOOLBOX_DIR/ops/backup.env"
      ;;
    5)
      echo "▶ Testing SSH connection..."
      if ssh -o ConnectTimeout=5 "${DEST_USER}@${DEST_HOST}" "echo OK"; then
        echo "✅ SSH connection successful"
      else
        echo "❌ SSH connection failed"
      fi
      echo "Press Enter to continue..."
      read -r
      ;;
    6)
      echo "▶ Adding to cron (daily at 2 AM)..."
      CRON_ENTRY="0 2 * * * $BACKUP_SCRIPT"
      (crontab -l 2>/dev/null; echo "$CRON_ENTRY") | crontab -
      echo "✅ Cron job added"
      echo "Press Enter to continue..."
      read -r
      ;;
    7)
      echo "Goodbye!"
      exit 0
      ;;
    *)
      echo "Invalid choice. Press Enter to continue..."
      read -r
      ;;
  esac
done
