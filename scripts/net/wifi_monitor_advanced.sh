#!/usr/bin/env bash
# wifi_monitor_advanced.sh - 增强版 WiFi 监控

TARGET="${1:-8.8.8.8}"
INTERVAL="${2:-2}"
MAX_COUNT="${3:-0}"  # 0 = 无限

# 信号处理
trap 'echo; echo "[INFO] Monitoring stopped by user"; cleanup; exit 0' INT TERM

cleanup() {
  # 显示统计
  if [[ $count -gt 0 ]]; then
    echo
    echo "════════════════════════════════════════"
    echo "  Statistics"
    echo "════════════════════════════════════════"
    echo "Total checks: $count"
    echo "Successful:   $success ($(awk "BEGIN {printf \"%.1f\", $success/$count*100}")%)"
    echo "Failed:       $failed ($(awk "BEGIN {printf \"%.1f\", $failed/$count*100}")%)"
    
    if [[ $success -gt 0 ]]; then
      echo "Avg latency:  ${total_latency}ms ($(awk "BEGIN {printf \"%.1f\", $total_latency/$success}") ms/ping)"
    fi
    echo "Duration:     $(($(date +%s) - start_time))s"
    echo "════════════════════════════════════════"
  fi
}

# 初始化
count=0
success=0
failed=0
total_latency=0
start_time=$(date +%s)

echo "════════════════════════════════════════"
echo "  WiFi Connection Monitor (Enhanced)"
echo "════════════════════════════════════════"
echo "Target:   $TARGET"
echo "Interval: ${INTERVAL}s"
[[ $MAX_COUNT -gt 0 ]] && echo "Max:      $MAX_COUNT checks"
echo
echo "Controls:"
echo "  Ctrl+C  : Stop monitoring"
echo "  q       : Quick stop (if interactive)"
echo "════════════════════════════════════════"
echo

# 主循环
while true; do
  count=$((count + 1))
  timestamp="$(date '+%H:%M:%S')"
  
  # Ping 测试
  if ping -c 1 -W 1 "$TARGET" >/dev/null 2>&1; then
    success=$((success + 1))
    latency=$(ping -c 1 "$TARGET" 2>/dev/null | grep 'time=' | awk -F'time=' '{print $2}' | awk '{print $1}' | cut -d'.' -f1)
    total_latency=$((total_latency + latency))
    
    # 颜色状态（如果终端支持）
    if [[ -t 1 ]]; then
      printf "\r\033[K[%s] #%-4d \033[32m✅ ONLINE\033[0m  | %3dms | ✅ %d ❌ %d" \
        "$timestamp" "$count" "$latency" "$success" "$failed"
    else
      printf "[%s] #%-4d ✅ ONLINE  | %3dms | Success: %d | Failed: %d\n" \
        "$timestamp" "$count" "$latency" "$success" "$failed"
    fi
  else
    failed=$((failed + 1))
    
    if [[ -t 1 ]]; then
      printf "\r\033[K[%s] #%-4d \033[31m❌ OFFLINE\033[0m | ✅ %d ❌ %d" \
        "$timestamp" "$count" "$success" "$failed"
    else
      printf "[%s] #%-4d ❌ OFFLINE | Success: %d | Failed: %d\n" \
        "$timestamp" "$count" "$success" "$failed"
    fi
    
    # 发送通知（如果失败）
    if command -v osascript >/dev/null 2>&1; then
      osascript -e "display notification \"Connection to $TARGET failed\" with title \"WiFi Monitor\""
    fi
  fi
  
  # 检查是否达到最大次数
  if [[ $MAX_COUNT -gt 0 ]] && [[ $count -ge $MAX_COUNT ]]; then
    echo
    echo "[INFO] Reached maximum count: $MAX_COUNT"
    break
  fi
  
  sleep "$INTERVAL"
done

cleanup
