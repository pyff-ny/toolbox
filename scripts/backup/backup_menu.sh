#!/usr/bin/env bash
# backup_menu.sh - 备份脚本专用交互式菜单

BACKUP_SCRIPT="$HOME/toolbox/scripts/backup/rsync_backup.sh"
LOG_DIR="$HOME/toolbox/Logs"

menu_backup() {
  cat <<'EOF'
╔═══════════════════════════════════════╗
║     Backup Script Interactive Menu   ║
╚═══════════════════════════════════════╝

1) Run Backup (Real)
2) Run Dry-Run (Test)
3) View Last Log
4) View All Logs
5) Edit Config
6) Test SSH Connection
7) Schedule Daily Backup
8) Exit

Enter choice [1-8]: 
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
      LAST_LOG=$(ls -t "$LOG_DIR"/rsync_backup_*.log 2>/dev/null | head -n 1)
      if [[ -n "$LAST_LOG" ]]; then
        echo "▶ Viewing: $LAST_LOG"
        less "$LAST_LOG"
      else
        echo "No logs found"
      fi
      ;;
    4)
      echo "▶ Available logs:"
      ls -lht "$LOG_DIR"/rsync_backup_*.log 2>/dev/null | head -n 20
      echo "Press Enter to continue..."
      read -r
      ;;
    5)
      ${EDITOR:-nano} "$HOME/toolbox/conf/backup.env"
      ;;
    6)
      echo "▶ Testing SSH connection..."
      source "$HOME/toolbox/conf/backup.env"
      if ssh -o ConnectTimeout=5 "${DEST_USER}@${DEST_HOST}" "echo OK"; then
        echo "✅ SSH connection successful"
      else
        echo "❌ SSH connection failed"
      fi
      echo "Press Enter to continue..."
      read -r
      ;;
    7)
      echo "▶ Adding to cron (daily at 2 AM)..."
      CRON_ENTRY="0 2 * * * $BACKUP_SCRIPT"
      (crontab -l 2>/dev/null; echo "$CRON_ENTRY") | crontab -
      echo "✅ Cron job added"
      echo "Press Enter to continue..."
      read -r
      ;;
    8)
      echo "Goodbye!"
      exit 0
      ;;
    *)
      echo "Invalid choice. Press Enter to continue..."
      read -r
      ;;
  esac
done
