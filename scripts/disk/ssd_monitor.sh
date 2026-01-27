#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$HOME/toolbox/scripts/disk/disk_health_check.sh"

# Ctrl+C 只退出 monitor，不影响主菜单
trap 'echo; echo "[INFO] Monitor stopped (Ctrl-C)"; exit 130' INT

exec "$SCRIPT" --monitor
