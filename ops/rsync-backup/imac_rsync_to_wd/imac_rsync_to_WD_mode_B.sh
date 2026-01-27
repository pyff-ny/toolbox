#!/bin/zsh
set -euo pipefail

# =========================
# User config
#使用时，先确认src/dest_vol是否正确
#这个版本是针对imac系统盘rsync到外置硬盘上的，镜像备份
# =========================
SRC="/Volumes/iMac_HDD_Backup/Macbook/Users/jiali/"
DEST_VOL="/Volumes/WD_HDD_Backup"          # ← 改成你的目标盘卷名挂载路径
DEST_BASE="${DEST_VOL}/Macbook/Users/jiali/"

#确认外置盘挂载
[[ -d "$DEST_VOL" ]] || { echo "DEST_VOL not mounted: $DEST_VOL"; exit 2; }

#防止dest为空导致灾难性---delete
[[ -n "${DEST_BASE:-}" && "$DEST_BASE" == /Volumes/* ]] || { echo "Bad DEST_BASE: $DEST_BASE"; exit 3; }

#####日志与可审计输出（强烈建议始终保留）
LOG_DIR="${DEST_BASE}/_logs"
mkdir -p "$LOG_DIR"
LOG="${LOG_DIR}/rsync_$(date +%Y%m%d_%H%M%S).log"


# Excludes (你已经验证过 0 报错的那套 + vanished 优化)
EXCLUDES=(
  "--exclude=.DS_Store"
  "--exclude=.Spotlight-V100/"
  "--exclude=.Trashes/"
  "--exclude=Library/Caches/"
  "--exclude=Library/Logs/"
  "--exclude=Library/Application Support/FileProvider/"
  "--exclude=Library/Group Containers/"
  "--exclude=Library/Containers/"
  "--exclude=Library/Application Support/CloudDocs/"
)

# Rsync基础选项
#说明：-E 在 macOS 下常用于保留扩展属性/资源叉；-h 可读；--itemize-changes 让你知道“变了什么”。
RSYNC_BASE=(
  -aEh --human-readable
  --info=progress2
  --itemize-changes
  --stats
  "${EXCLUDES[@]}"
)

###===========Mode B：版本快照（可回滚，适合重要资料）=======
# 适用场景：你最怕“误删/误覆盖”，希望能回到昨天/上周的状态；同时又不想每次全量复制占爆空间。
# 这里给你 rsync 的经典“硬链接快照增量”（--link-dest）：
# 每次生成一个新快照目录：snapshots/2026-01-17_1830/
# 未变化的文件用硬链接指向上一份快照（节省空间）
# 变化的文件才真实占用新增空间

####=====run rsync========
SNAP_DIR="${DEST_BASE}/snapshots"
mkdir -p "$SNAP_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
NEW="${SNAP_DIR}/${TS}"
LATEST="${SNAP_DIR}/latest"

mkdir -p "$NEW"

# 如果已有 latest，则用 --link-dest 做增量快照
if [[ -d "$LATEST" ]]; then
  rsync "${RSYNC_BASE[@]}" \
    --delete \
    --link-dest="$LATEST" \
    --log-file="$LOG" \
    "$SRC" "$NEW"
else
  rsync "${RSYNC_BASE[@]}" \
    --delete \
    --log-file="$LOG" \
    "$SRC" "$NEW"
fi

# 更新 latest 指向
# 例如保留最近30份log
#你也可以把快照保留策略改成：每天 1 份保留 14 天、每周 1 份保留 8 周等，但先从“最近 N 份”最简单稳妥。
rm -f "$LATEST"
ln -s "$NEW" "$LATEST"
ls -1dt "${SNAP_DIR}"/20* | tail -n +31 | xargs -I{} rm -rf "{}"
