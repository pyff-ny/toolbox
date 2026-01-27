#!/usr/bin/env bash
# view_backup_logs.sh - 备份日志查看工具

set -euo pipefail

LOG_DIR="${LOG_DIR:-$HOME/toolbox/Logs}"

# 颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

print_header() {
  echo -e "${BLUE}${BOLD}"
  echo "╔════════════════════════════════════════════════════════╗"
  echo "║          📋 Backup Logs Viewer                         ║"
  echo "╚════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

list_logs() {
  echo -e "${BOLD}Recent Backup Logs:${NC}"
  echo "────────────────────────────────────────────────────────"
  
  if ! ls -t "$LOG_DIR"/rsync_backup_*.log >/dev/null 2>&1; then
    echo "No logs found in: $LOG_DIR"
    return 1
  fi
  
  local count=0
  ls -t "$LOG_DIR"/rsync_backup_*.log | head -n 20 | while IFS= read -r log; do
    count=$((count + 1))
    local basename=$(basename "$log")
    local size=$(du -h "$log" | cut -f1)
    local time=$(echo "$basename" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}' || echo "unknown")
    
    # 提取状态
    local status="UNKNOWN"
    if grep -q '"status":"OK"' "$log" 2>/dev/null; then
      status="${GREEN}✅ OK${NC}"
    elif grep -q '"status":"WARN' "$log" 2>/dev/null; then
      status="${YELLOW}⚠️  WARN${NC}"
    elif grep -q '"status":"ERROR' "$log" 2>/dev/null; then
      status="${RED}❌ ERROR${NC}"
    fi
    
    printf "%2d) %s | %6s | %s\n" "$count" "$time" "$size" "$(echo -e "$status")"
  done
  
  echo
}

view_log() {
  local log_num="$1"
  local log_file
  
  log_file=$(ls -t "$LOG_DIR"/rsync_backup_*.log | sed -n "${log_num}p")
  
  if [[ -z "$log_file" ]]; then
    echo -e "${RED}[ERROR]${NC} Log #$log_num not found"
    return 1
  fi
  
  echo -e "${BOLD}Viewing: $(basename "$log_file")${NC}"
  echo "────────────────────────────────────────────────────────"
  echo
  
  less "$log_file"
}

show_summary() {
  local log_num="$1"
  local log_file
  
  log_file=$(ls -t "$LOG_DIR"/rsync_backup_*.log | sed -n "${log_num}p")
  
  if [[ -z "$log_file" ]]; then
    echo -e "${RED}[ERROR]${NC} Log #$log_num not found"
    return 1
  fi
  
  echo -e "${BOLD}Summary: $(basename "$log_file")${NC}"
  echo "────────────────────────────────────────────────────────"
  
  # 提取 JSON
  if grep -q '\[SUMMARY_JSON\]' "$log_file"; then
    local json=$(grep '\[SUMMARY_JSON\]' "$log_file" | sed 's/\[SUMMARY_JSON\] //')
    
    echo "Status:       $(echo "$json" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)"
    echo "Exit Code:    $(echo "$json" | grep -o '"code":[0-9]*' | cut -d':' -f2)"
    echo "Dry Run:      $(echo "$json" | grep -o '"dry_run":[^,}]*' | cut -d':' -f2)"
    echo "Log File:     $(echo "$json" | grep -o '"log":"[^"]*"' | cut -d'"' -f4)"
  fi
  
  # 提取摘要行
  echo
  if grep -q 'SUMMARY |' "$log_file"; then
    echo "Details:"
    grep 'SUMMARY |' "$log_file" | sed 's/^/  /'
  fi
  
  echo
}

search_logs() {
  local keyword="$1"
  
  echo -e "${BOLD}Searching for: $keyword${NC}"
  echo "────────────────────────────────────────────────────────"
  
  grep -r "$keyword" "$LOG_DIR"/rsync_backup_*.log 2>/dev/null | while IFS=: read -r file match; do
    echo "$(basename "$file"): $match"
  done
}

show_stats() {
  echo -e "${BOLD}Backup Statistics:${NC}"
  echo "────────────────────────────────────────────────────────"
  
  local total=$(ls "$LOG_DIR"/rsync_backup_*.log 2>/dev/null | wc -l)
  local success=$(grep -l '"status":"OK"' "$LOG_DIR"/rsync_backup_*.log 2>/dev/null | wc -l)
  local failed=$(grep -l '"status":"ERROR' "$LOG_DIR"/rsync_backup_*.log 2>/dev/null | wc -l)
  
  echo "Total backups:     $total"
  echo "Successful:        $success ($(awk "BEGIN {printf \"%.1f\", $success*100/$total}")%)"
  echo "Failed:            $failed ($(awk "BEGIN {printf \"%.1f\", $failed*100/$total}")%)"
  
  # 最后一次备份
  local last_log=$(ls -t "$LOG_DIR"/rsync_backup_*.log 2>/dev/null | head -n 1)
  if [[ -n "$last_log" ]]; then
    local last_time=$(basename "$last_log" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}')
    echo "Last backup:       $last_time"
  fi
  
  echo
}

main_menu() {
  while true; do
    print_header
    echo
    
    list_logs
    
    echo -e "${BOLD}Actions:${NC}"
    echo "  [1-20]  View log details"
    echo "  s       Show statistics"
    echo "  f       Search in logs"
    echo "  r       Refresh list"
    echo "  q       Quit"
    echo
    read -r -p "Choice: " choice
    
    case "$choice" in
      [1-9]|[1-9][0-9])
        echo
        show_summary "$choice"
        echo
        read -r -p "View full log? [y/N]: " view
        if [[ "$view" =~ ^[Yy] ]]; then
          view_log "$choice"
        fi
        echo
        read -r -p "Press Enter to continue..."
        ;;
      s|S)
        clear
        print_header
        show_stats
        read -r -p "Press Enter to continue..."
        ;;
      f|F)
        echo
        read -r -p "Search keyword: " keyword
        echo
        search_logs "$keyword"
        echo
        read -r -p "Press Enter to continue..."
        ;;
      r|R)
        clear
        ;;
      q|Q)
        echo "Goodbye!"
        exit 0
        ;;
      *)
        echo "Invalid choice"
        sleep 1
        ;;
    esac
    
    clear
  done
}

# 命令行参数
if [[ $# -gt 0 ]]; then
  case "$1" in
    --list|-l)
      list_logs
      ;;
    --stats|-s)
      show_stats
      ;;
    --view|-v)
      view_log "${2:-1}"
      ;;
    --search|-f)
      search_logs "${2:-}"
      ;;
    *)
      echo "Usage: $0 [--list|--stats|--view N|--search KEYWORD]"
      exit 1
      ;;
  esac
else
  main_menu
fi
