#!/usr/bin/env bash
# view_backup_logs_enhanced.sh - 增强版备份日志查看工具

set -euo pipefail

LOG_DIR="${LOG_DIR:-$HOME/toolbox/_out/Logs}"

# 颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

print_header() {
  echo -e "${BLUE}${BOLD}"
  echo "╔════════════════════════════════════════════════════════╗"
  echo "║          📋 Backup Logs Viewer (Enhanced)             ║"
  echo "╚════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

detect_log_status() {
  local log="$1"
  local status="UNKNOWN"
  
  # 方法1：检查 SUMMARY_JSON（新格式）
  if grep -q '\[SUMMARY_JSON\]' "$log" 2>/dev/null; then
    if grep -q '"status":"OK"' "$log" 2>/dev/null; then
      status="OK"
    elif grep -q '"status":"WARN' "$log" 2>/dev/null; then
      status="WARN"
    elif grep -q '"status":"ERROR' "$log" 2>/dev/null; then
      status="ERROR"
    fi
  
  # 方法2：检查 SUMMARY 行（旧格式）
  elif grep -q 'SUMMARY |' "$log" 2>/dev/null; then
    if grep 'SUMMARY |' "$log" | grep -q 'status=OK'; then
      status="OK"
    elif grep 'SUMMARY |' "$log" | grep -q 'status=WARN'; then
      status="WARN"
    elif grep 'SUMMARY |' "$log" | grep -q 'status=ERROR'; then
      status="ERROR"
    fi
  
  # 方法3：检查退出码
  elif grep -q 'exit.*code.*0' "$log" 2>/dev/null || grep -q 'code=0' "$log" 2>/dev/null; then
    status="OK"
  
  # 方法4：检查错误关键词
  elif grep -qE '\[ERROR\]|rsync error:|failed' "$log" 2>/dev/null; then
    status="ERROR"
  
  # 方法5：检查是否完成
  elif grep -q 'completed' "$log" 2>/dev/null; then
    status="OK"
  fi
  
  echo "$status"
}

format_status() {
  local status="$1"
  case "$status" in
    OK)      echo -e "${GREEN}✅ OK${NC}" ;;
    WARN)    echo -e "${YELLOW}⚠️  WARN${NC}" ;;
    ERROR)   echo -e "${RED}❌ ERROR${NC}" ;;
    UNKNOWN) echo -e "${GRAY}❓ UNKNOWN${NC}" ;;
    *)       echo -e "${GRAY}$status${NC}" ;;
  esac
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
    
    # 检测状态（增强版）
    local raw_status=$(detect_log_status "$log")
    local status=$(format_status "$raw_status")
    
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
  
  local status=$(detect_log_status "$log_file")
  echo "Status: $(format_status "$status")"
  
  # 尝试提取 JSON（新格式）
  if grep -q '\[SUMMARY_JSON\]' "$log_file"; then
    local json=$(grep '\[SUMMARY_JSON\]' "$log_file" | sed 's/\[SUMMARY_JSON\] //')
    
    echo "Exit Code:    $(echo "$json" | grep -o '"code":[0-9]*' | cut -d':' -f2 || echo "N/A")"
    echo "Dry Run:      $(echo "$json" | grep -o '"dry_run":[^,}]*' | cut -d':' -f2 || echo "N/A")"
    
    local transferred=$(echo "$json" | grep -o '"transferred_mb":[0-9.]*' | cut -d':' -f2 || echo "0")
    echo "Transferred:  ${transferred}MB"
    
    local created=$(echo "$json" | grep -o '"files_created":[0-9]*' | cut -d':' -f2 || echo "0")
    local deleted=$(echo "$json" | grep -o '"files_deleted":[0-9]*' | cut -d':' -f2 || echo "0")
    echo "Files:        +$created / -$deleted"
    
    local elapsed=$(echo "$json" | grep -o '"elapsed_human":"[^"]*"' | cut -d'"' -f4 || echo "N/A")
    echo "Duration:     $elapsed"
    
    local remote=$(echo "$json" | grep -o '"remote":"[^"]*"' | cut -d'"' -f4 || echo "N/A")
    echo "Remote:       $remote"
    
    local log_path=$(echo "$json" | grep -o '"log":"[^"]*"' | cut -d'"' -f4 || echo "N/A")
    echo "Log File:     $log_path"
  
  # 旧格式：提取 SUMMARY 行
  elif grep -q 'SUMMARY |' "$log_file"; then
    echo
    echo "Details (old format):"
    grep 'SUMMARY |' "$log_file" | sed 's/^/  /'
  
  # 最基本的信息
  else
    echo
    echo "Basic Info:"
    echo "  File size:  $(du -h "$log_file" | cut -f1)"
    echo "  Lines:      $(wc -l < "$log_file")"
    echo "  Created:    $(stat -f%Sm -t '%Y-%m-%d %H:%M:%S' "$log_file" 2>/dev/null || stat -c%y "$log_file" 2>/dev/null || echo "N/A")"
    
    # 尝试找到一些关键信息
    if grep -q 'transferred' "$log_file"; then
      echo "  Contains transfer info: Yes"
    fi
    if grep -qE '\[ERROR\]|error:' "$log_file"; then
      echo "  Errors found: Yes"
      echo "    $(grep -c -E '\[ERROR\]|error:' "$log_file") error lines"
    fi
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
  
  local total=$(ls "$LOG_DIR"/rsync_backup_*.log 2>/dev/null | wc -l | xargs)
  
  if [[ $total -eq 0 ]]; then
    echo "No backup logs found"
    return
  fi
  
  # 统计各种状态
  local ok=0 warn=0 error=0 unknown=0
  
  for log in "$LOG_DIR"/rsync_backup_*.log; do
    local status=$(detect_log_status "$log")
    case "$status" in
      OK)      ((ok++)) ;;
      WARN)    ((warn++)) ;;
      ERROR)   ((error++)) ;;
      UNKNOWN) ((unknown++)) ;;
    esac
  done
  
  echo "Total backups:     $total"
  echo "Status breakdown:"
  echo "  ✅ Successful:   $ok ($(awk "BEGIN {if($total>0) printf \"%.1f\", $ok*100/$total; else print 0}")%)"
  echo "  ⚠️  Warnings:     $warn ($(awk "BEGIN {if($total>0) printf \"%.1f\", $warn*100/$total; else print 0}")%)"
  echo "  ❌ Failed:       $error ($(awk "BEGIN {if($total>0) printf \"%.1f\", $error*100/$total; else print 0}")%)"
  echo "  ❓ Unknown:      $unknown ($(awk "BEGIN {if($total>0) printf \"%.1f\", $unknown*100/$total; else print 0}")%)"
  
  # 最后一次备份
  local last_log=$(ls -t "$LOG_DIR"/rsync_backup_*.log 2>/dev/null | head -n 1)
  if [[ -n "$last_log" ]]; then
    local last_time=$(basename "$last_log" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}')
    local last_status=$(detect_log_status "$last_log")
    echo
    echo "Last backup:"
    echo "  Time:   $last_time"
    echo "  Status: $(format_status "$last_status")"
  fi
  
  echo
}

cleanup_logs() {
  echo -e "${BOLD}Log Cleanup${NC}"
  echo "────────────────────────────────────────────────────────"
  
  local total=$(ls "$LOG_DIR"/rsync_backup_*.log 2>/dev/null | wc -l | xargs)
  
  echo "Total logs: $total"
  echo
  echo "Options:"
  echo "  1) Keep last 10, delete older"
  echo "  2) Keep last 20, delete older"
  echo "  3) Delete logs older than 30 days"
  echo "  4) Delete all UNKNOWN status logs"
  echo "  5) Cancel"
  echo
  read -r -p "Choice [1-5]: " choice
  
  case "$choice" in
    1)
      echo "Keeping last 10 logs..."
      ls -t "$LOG_DIR"/rsync_backup_*.log | tail -n +11 | xargs -r rm -f
      echo "✅ Done"
      ;;
    2)
      echo "Keeping last 20 logs..."
      ls -t "$LOG_DIR"/rsync_backup_*.log | tail -n +21 | xargs -r rm -f
      echo "✅ Done"
      ;;
    3)
      echo "Deleting logs older than 30 days..."
      find "$LOG_DIR" -name "rsync_backup_*.log" -mtime +30 -delete
      echo "✅ Done"
      ;;
    4)
      echo "Scanning for UNKNOWN status logs..."
      local deleted=0
      for log in "$LOG_DIR"/rsync_backup_*.log; do
        local status=$(detect_log_status "$log")
        if [[ "$status" == "UNKNOWN" ]]; then
          echo "  Deleting: $(basename "$log")"
          rm -f "$log"
          ((deleted++))
        fi
      done
      echo "✅ Deleted $deleted logs"
      ;;
    *)
      echo "Cancelled"
      ;;
  esac
  
  echo
  read -r -p "Press Enter to continue..."
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
    echo "  c       Cleanup old logs"
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
      c|C)
        clear
        print_header
        cleanup_logs
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
      show_summary "${2:-1}"
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
