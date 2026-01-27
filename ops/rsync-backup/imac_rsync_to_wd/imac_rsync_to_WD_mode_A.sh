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

# Mode A：镜像同步（最快、最省心，适合日常）
# 适用场景：你只想外置盘上永远是“最新一份”，不太需要找回“被误删/被覆盖的旧版本”。
# 目标：DEST 始终长得像 SRC
# 风险：如果 SRC 误删文件，DEST 也会被删除（因为 --delete）


####=====run rsync========
DEST="${DEST_BASE}/mirror"
mkdir -p "$DEST"

rsync "${RSYNC_BASE[@]}" \
  --delete \
  --dry-run \
  --log-file="$LOG" \
  "$SRC" "$DEST"
# 先加--dry-run, rsync "${RSYNC_BASE[@]}" --delete --dry-run --log-file="$LOG" "$SRC" "$DEST"
# 没问题再去掉 --dry-run，正式跑