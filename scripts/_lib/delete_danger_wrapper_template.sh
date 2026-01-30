#!/usr/bin/env bash
#要点（你现在这张截图已经全部做到）：
#delete 二次确认 只在 wrapper
#wrapper 用 exec 交棒，避免多一层进程、exit code 更干净
#exit 0 表示“用户取消不是错误”（toolbox 不用报错）
set -Eeuo pipefail

TOOLBOX_DIR="${TOOLBOX_DIR:-$HOME/toolbox}"
LIB_DIR="$TOOLBOX_DIR/scripts/_lib"

# shellcheck source=/dev/null
source "$TOOLBOX_DIR/_lib/rules.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/log.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/ux.sh"

log_warn "LOCALLY" "DANGER: rsync --delete will remove files on target that are missing locally."
sleep 1
ux_confirm_delete "Type YES to confirm DELETE sync: " || {
  log_warn "LOCALLY" "Cancelled"
  exit 0
}

exec "$TOOLBOX_DIR/scripts/backup/sync_reports.sh" --real --delete "$@"
#要点（你现在这张截图已经全部做到）：
#delete 二次确认 只在 wrapper
#wrapper 用 exec 交棒，避免多一层进程、exit code 更干净
#exit 0 表示“用户取消不是错误”（toolbox 不用报错）