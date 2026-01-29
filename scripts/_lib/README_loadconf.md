用法示例（在你的脚本里怎么接）
比如 scripts/backup/rsync_backup_final.sh 顶部：
#!/usr/bin/env bash
set -Eeuo pipefail

TOOLBOX_DIR="${TOOLBOX_DIR:-$HOME/toolbox}"
# shellcheck source=/dev/null
source "$TOOLBOX_DIR/scripts/_lib/load_conf.sh"

load_conf "backup" "SRC_DIR" "DST_DIR" || exit $?

# 这里开始使用 $SRC_DIR / $DST_DIR
echo "SRC=$SRC_DIR"
echo "DST=$DST_DIR"
