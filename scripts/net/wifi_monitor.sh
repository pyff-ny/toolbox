#!/usr/bin/env bash
# wifi_monitor.sh - WiFi 连接监控

TARGET="${1:-8.8.8.8}"
INTERVAL="${2:-2}"

echo "════════════════════════════════════════"
echo "  WiFi Connection Monitor"
echo "════════════════════════════════════════"
echo "Target: $TARGET"
echo "Interval: ${INTERVAL}s"
echo "Press Ctrl+C to stop"
echo "════════════════════════════════════════"
echo

# 计数器
count=0
success=0
failed=0

while true; do
  count=$((count + 1))
  timestamp="$(date '+%H:%M:%S')"
  
  # Ping 测试
  if ping -c 1 -W 1 "$TARGET" >/dev/null 2>&1; then
    success=$((success + 1))
    latency=$(ping -c 1 "$TARGET" 2>/dev/null | grep 'time=' | awk -F'time=' '{print $2}' | awk '{print $1}')
    printf "[%s] #%-4d ✅ ONLINE  | Latency: %sms | Success: %d | Failed: %d\n" \
      "$timestamp" "$count" "$latency" "$success" "$failed"
  else
    failed=$((failed + 1))
    printf "[%s] #%-4d ❌ OFFLINE | Success: %d | Failed: %d\n" \
      "$timestamp" "$count" "$success" "$failed"
  fi
  
  sleep "$INTERVAL"
done
