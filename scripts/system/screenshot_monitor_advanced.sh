#!/usr/bin/env bash
# screenshot_monitor_advanced.sh - 增强版截屏监控

set -euo pipefail

# ═══════════════════════════════════════════════════════════
# 配置
# ═══════════════════════════════════════════════════════════

# 加载配置（如果存在）
TOOLBOX_ROOT="${TOOLBOX_ROOT:-$HOME/toolbox}"
if [[ -f "$TOOLBOX_ROOT/_lib/load_conf.sh" ]]; then
  source "$TOOLBOX_ROOT/_lib/load_conf.sh"
fi

# 截屏监控目录
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$HOME/Desktop}"

# 自动整理到的目录
ORGANIZE_DIR="${ORGANIZE_DIR:-$HOME/Pictures/Screenshots}"

# 日志目录
LOG_DIR="${LOG_DIR:-$TOOLBOX_ROOT/_out/Logs}"
LOG_FILE="$LOG_DIR/screenshot_monitor.log"

# 功能开关
AUTO_OPEN="${AUTO_OPEN:-true}"           # 自动打开
AUTO_ORGANIZE="${AUTO_ORGANIZE:-false}"  # 自动整理
AUTO_UPLOAD="${AUTO_UPLOAD:-false}"      # 自动上传（需配置）
SHOW_NOTIFICATION="${SHOW_NOTIFICATION:-true}"  # 显示通知

# 创建必要的目录
mkdir -p "$LOG_DIR"
[[ "$AUTO_ORGANIZE" == "true" ]] && mkdir -p "$ORGANIZE_DIR"

# ═══════════════════════════════════════════════════════════
# 函数
# ═══════════════════════════════════════════════════════════

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# 检测截屏文件
is_screenshot() {
  local file="$1"
  local basename="$(basename "$file")"
  
  # macOS 截屏命名模式
  [[ "$basename" =~ ^(Screenshot|Screen\ Shot|截屏).*\.(png|jpg|jpeg)$ ]]
}

# 在 Finder 中打开
open_in_finder() {
  local file="$1"
  
  osascript <<EOF
tell application "Finder"
  reveal POSIX file "$file"
  activate
end tell
EOF
}

# 显示通知
show_notification() {
  local title="$1"
  local message="$2"
  local sound="${3:-Glass}"
  
  osascript <<EOF
display notification "$message" with title "$title" sound name "$sound"
EOF
}

# 整理截屏到指定目录
organize_screenshot() {
  local file="$1"
  local date_dir="$ORGANIZE_DIR/$(date '+%Y-%m')"
  
  mkdir -p "$date_dir"
  
  local new_path="$date_dir/$(basename "$file")"
  mv "$file" "$new_path"
  
  log "Organized to: $new_path"
  echo "$new_path"
}

# 复制到剪贴板
copy_to_clipboard() {
  local file="$1"
  osascript <<EOF
set the clipboard to (read (POSIX file "$file") as JPEG picture)
EOF
}

# 上传到图床（示例：imgur）
upload_screenshot() {
  local file="$1"
  
  # 这里需要配置你的上传服务
  # 示例使用 imgur
  if command -v curl >/dev/null 2>&1; then
    local response=$(curl -s -X POST \
      -H "Authorization: Client-ID YOUR_CLIENT_ID" \
      -F "image=@$file" \
      https://api.imgur.com/3/image)
    
    local url=$(echo "$response" | grep -o '"link":"[^"]*"' | cut -d'"' -f4)
    
    if [[ -n "$url" ]]; then
      echo "$url" | pbcopy
      log "Uploaded to: $url (copied to clipboard)"
      return 0
    fi
  fi
  
  return 1
}

# 处理新截屏
handle_screenshot() {
  local file="$1"
  
  # 检查是否是截屏
  if ! is_screenshot "$file"; then
    return
  fi
  
  log "════════════════════════════════════════"
  log "New screenshot: $(basename "$file")"
  
  # 等待文件写入完成
  sleep 0.5
  
  # 自动整理
  if [[ "$AUTO_ORGANIZE" == "true" ]]; then
    file=$(organize_screenshot "$file")
  fi
  
  # 自动打开
  if [[ "$AUTO_OPEN" == "true" ]]; then
    open_in_finder "$file"
    log "Opened in Finder"
  fi
  
  # 自动上传
  if [[ "$AUTO_UPLOAD" == "true" ]]; then
    if upload_screenshot "$file"; then
      log "Uploaded successfully"
    else
      log "Upload failed"
    fi
  fi
  
  # 显示通知
  if [[ "$SHOW_NOTIFICATION" == "true" ]]; then
    local msg="$(basename "$file")"
    [[ "$AUTO_ORGANIZE" == "true" ]] && msg="$msg\n已整理到图片文件夹"
    show_notification "截屏已保存" "$msg"
  fi
  
  log "Processing completed"
}

# 显示配置信息
show_config() {
  cat <<EOF
════════════════════════════════════════
  Screenshot Monitor Configuration
════════════════════════════════════════
Watching:         $SCREENSHOT_DIR
Organize to:      $ORGANIZE_DIR
Log file:         $LOG_FILE

Features:
  Auto Open:      $AUTO_OPEN
  Auto Organize:  $AUTO_ORGANIZE
  Auto Upload:    $AUTO_UPLOAD
  Notification:   $SHOW_NOTIFICATION
════════════════════════════════════════
EOF
}

# ═══════════════════════════════════════════════════════════
# 主程序
# ═══════════════════════════════════════════════════════════

main() {
  log "Screenshot monitor started (advanced mode)"
  show_config | tee -a "$LOG_FILE"
  
  # 检查依赖
  if ! command -v fswatch >/dev/null 2>&1; then
    log "ERROR: fswatch not found. Install: brew install fswatch"
    exit 1
  fi
  
  # 检查目录
  if [[ ! -d "$SCREENSHOT_DIR" ]]; then
    log "ERROR: Directory does not exist: $SCREENSHOT_DIR"
    exit 1
  fi
  
  # 显示启动通知
  if [[ "$SHOW_NOTIFICATION" == "true" ]]; then
    show_notification "截屏监控已启动" "正在监控: $SCREENSHOT_DIR"
  fi
  
  # 监控截屏目录
  fswatch --event Created \
          --exclude '\.tmp$' \
          --exclude '\.DS_Store' \
          "$SCREENSHOT_DIR" | while read -r file
  do
    handle_screenshot "$file" || true
  done
}

# 信号处理
trap 'log "Screenshot monitor stopped"; exit 0' INT TERM

# 命令行参数
case "${1:-start}" in
  start)
    main
    ;;
  config)
    show_config
    ;;
  test)
    # 测试通知
    show_notification "测试通知" "Screenshot Monitor 工作正常"
    ;;
  *)
    echo "Usage: $0 {start|config|test}"
    exit 1
    ;;
esac
