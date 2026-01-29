#!/usr/bin/env bash
# screenshot_monitor_fixed.sh - 修复版本（处理空格和隐藏文件）

set -euo pipefail

# ═══════════════════════════════════════════════════════════
# 配置
# ═══════════════════════════════════════════════════════════

SCREENSHOT_DIR="$HOME/Desktop/截屏"
LOG_FILE="$HOME/toolbox/_out/Logs/screenshot_monitor.log"

mkdir -p "$(dirname "$LOG_FILE")"

# ═══════════════════════════════════════════════════════════
# 函数
# ═══════════════════════════════════════════════════════════

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# 处理新截屏
handle_new_screenshot() {
  local file="$1"
  local basename
  basename="$(basename "$file")"
  
  log "════════════════════════════════════════"
  log "New file detected: $basename"
  log "Full path: $file"
  
  # 跳过隐藏文件（以 . 开头的文件）
  if [[ "$basename" =~ ^\. ]]; then
    log "Skipping hidden file: $basename"
    return 0
  fi
  
  # 跳过临时文件
  if [[ "$basename" =~ (\.tmp|\.download|\.part)$ ]]; then
    log "Skipping temporary file: $basename"
    return 0
  fi
  
  # 检查是否是图片文件
  if [[ ! "$basename" =~ \.(png|jpg|jpeg|PNG|JPG|JPEG)$ ]]; then
    log "Not an image file, ignoring"
    return 0
  fi
  
  log "✓ Confirmed as image file"
  
  # 等待文件完全写入
  log "Waiting for file to complete..."
  sleep 1
  
  # 验证文件存在（使用引号保护路径）
  if [[ ! -f "$file" ]]; then
    log "ERROR: File not found: $file"
    log "Checking if file exists without quotes..."
    ls -la "$SCREENSHOT_DIR" | grep -F "$basename" | tee -a "$LOG_FILE" || true
    return 1
  fi
  
  # 获取文件信息
  local file_size
  file_size=$(ls -lh "$file" | awk '{print $5}')
  log "✓ File exists, size: $file_size"
  
  # 在 Finder 中打开（方法1：open -R）
  log "Method 1: Using open -R..."
  if open -R "$file" 2>&1 | tee -a "$LOG_FILE"; then
    log "✓ Successfully opened in Finder (open -R)"
  else
    log "✗ open -R failed, trying alternative method"
    
    # 备用方法2：osascript
    log "Method 2: Using osascript..."
    if osascript -e "tell application \"Finder\" to reveal POSIX file \"$file\"" 2>&1 | tee -a "$LOG_FILE"; then
      log "✓ Successfully opened in Finder (osascript)"
      osascript -e "tell application \"Finder\" to activate" 2>/dev/null || true
    else
      log "✗ osascript also failed"
    fi
  fi
  
  # 显示系统通知
  osascript -e "display notification \"$basename\" with title \"新截屏已保存\" sound name \"Glass\"" 2>/dev/null || true
  
  # 播放提示音
  afplay /System/Library/Sounds/Glass.aiff 2>/dev/null &
  
  log "✓ Processing completed successfully"
}

# ═══════════════════════════════════════════════════════════
# 主程序
# ═══════════════════════════════════════════════════════════

main() {
  log "════════════════════════════════════════"
  log "Screenshot Monitor Started (Fixed Version)"
  log "════════════════════════════════════════"
  log "Monitoring directory: $SCREENSHOT_DIR"
  log "Log file: $LOG_FILE"
  log "════════════════════════════════════════"
  
  # 检查 fswatch
  if ! command -v fswatch >/dev/null 2>&1; then
    echo "[ERROR] fswatch not found"
    echo "Install with: brew install fswatch"
    exit 1
  fi
  log "✓ fswatch: $(which fswatch)"
  
  # 检查并创建目录
  if [[ ! -d "$SCREENSHOT_DIR" ]]; then
    log "Creating directory: $SCREENSHOT_DIR"
    mkdir -p "$SCREENSHOT_DIR"
  fi
  log "✓ Directory exists: $SCREENSHOT_DIR"
  
  # 显示目录中的文件
  log "Current files in directory:"
  ls -la "$SCREENSHOT_DIR" 2>/dev/null | tail -n 5 | tee -a "$LOG_FILE" || log "  (empty)"
  
  # 启动通知
  osascript -e 'display notification "正在监控 ~/Desktop/截屏" with title "截屏监控已启动" sound name "Purr"' 2>/dev/null || true
  
  log "════════════════════════════════════════"
  log "Monitoring started"
  log "Press Ctrl+C to stop"
  log "════════════════════════════════════════"
  
  echo
  echo "🎯 Screenshot Monitor is running..."
  echo "📁 Watching: $SCREENSHOT_DIR"
  echo "📋 Log: $LOG_FILE"
  echo
  echo "Press Ctrl+C to stop"
  echo
  
  # 开始监控
  # 使用 null 分隔符 (-0) 正确处理包含空格和特殊字符的文件名
  fswatch -0 \
          --event Created \
          --exclude '\.DS_Store' \
          "$SCREENSHOT_DIR" | while IFS= read -r -d '' file
  do
    # 确保文件路径正确传递（保留引号）
    handle_new_screenshot "$file" || log "WARNING: Failed to process: $file"
  done
}

# 信号处理
trap 'echo; log "Screenshot monitor stopped"; exit 0' INT TERM

# 运行
main "$@"
