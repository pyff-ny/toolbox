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

#==========Mode C：审计/排障模式（不写入或只做变化清单）=======
#===适用场景：你不确定这次会发生什么（尤其担心 --delete），或者你在排查“为什么 iMac 上跑得慢/权限报错/目录层级不对”。


####=====run rsync========
DEST="${DEST_BASE}/mirror"
mkdir -p "$DEST"

###演练（dry run）
rsync "${RSYNC_BASE[@]}" \
  --delete \
  --dry-run \
  --log-file="$LOG" \
  "$SRC" "$DEST"

# 生成“变化清单”便于复盘
REPORT="${LOG_DIR}/changes_$(date +%Y%m%d_%H%M%S).txt"

rsync "${RSYNC_BASE[@]}" \
  --delete \
  --dry-run \
  --itemize-changes \
  "$SRC" "$DEST" | tee "$REPORT"
