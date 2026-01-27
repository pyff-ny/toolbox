#!/bin/zsh
#!/bin/bash

# =================================================================
# 脚本名称: backup.sh
# 功能: 使用 rsync 进行安全、增量的磁盘/文件夹备份
# 适用系统: macOS (Sequoia/Tahoe), Linux
# =================================================================

# --- 配置部分 ---
# 源路径 (请确保末尾带 / 表示备份目录下的内容)
SOURCE="/Users/jiali/Documents/"

# 目标路径 (通常是外置硬盘挂载点)
DESTINATION="/Volumes/iMac_HDD_Backup/imac_rsync_Backup/"

# 日志文件路径
LOG_FILE="$HOME/Desktop/backup_log.txt"

# 排除列表 (不备份这些文件)
EXCLUDES=(
    "--exclude=.DS_Store"
    "--exclude=.Trash"
    "--exclude=node_modules"
    "--exclude=Cache"
    "--exclude=Caches"
    "--exclude=.git"
    "--exclude=*.tmp"
)

# --- 逻辑部分 ---

# 1. 检查目标盘是否已挂载
if [ ! -d "$DESTINATION" ]; then
    echo "错误: 找不到目标目录 $DESTINATION，请检查备份盘是否已连接。"
    exit 1
fi

echo "--- 备份开始: $(date '+%Y-%m-%d %H:%M:%S') ---" | tee -a "$LOG_FILE"

# 2. 执行 rsync 命令
# -a: 归档模式 (保留权限、时间等)
# -v: 显示详情
# -z: 传输时压缩 (本地对本地可去掉)
# --delete: 源端删了，目标端也删 (保持完全一致)
# --progress: 显示进度
# -E: (macOS特有) 保留扩展属性和元数据
rsync -avEh --delete "${EXCLUDES[@]}" --progress "$SOURCE" "$DESTINATION" 2>&1 | tee -a "$LOG_FILE"

# 3. 检查执行结果
if [ $? -eq 0 ]; then
    echo "--- 备份成功完成 ---" | tee -a "$LOG_FILE"
else
    echo "--- 备份过程中出现错误，请检查日志 ---" | tee -a "$LOG_FILE"
fi

echo "-------------------------------------------" >> "$LOG_FILE"
