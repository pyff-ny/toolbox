# rsync Backup (MacBook → iMac via SSH)

## 目标
- 用 rsync over SSH 把本机 `$HOME/` 镜像备份到远端 iMac 的外置盘目录。
- 备份类型：Mirror（启用 `--delete`，目标保持与源一致）
- 重点：**删前审查（dry-run + delete 列表）** + **恢复演练** + **证据留存（logs/reports）**

## 拓扑
- Source (local): `${SRC}`（默认 `$HOME/`）
- Destination (remote): `${DEST_USER}@${DEST_HOST}:${REMOTE_DEST_PATH}/Users/<local_user>/`
- Transport: SSH（推荐使用 `<LocalHostName>.local`）
- Remote disk example: `/Volumes/iMac_HDD_Backup/Macbook`

## 快速开始
1. 配置文件：复制并填写
   - `conf/backup.env.example` → `conf/backup.env`
2. Dry-run（必做）：
   - `bin/backup.sh --dry-run`
3. 检查删除项（必做）：
   - `bin/backup.sh --dry-run | grep '^\*deleting' | head -n 50`
4. Real run：
   - `bin/backup.sh`

## 日志与报告
- Logs: `logs/rsync_backup_*.log`
- Verification reports: `reports/verify_YYYY-MM-DD.md`

## 恢复
- 见 `docs/RESTORE.md`

## 排错
- 见 `docs/TROUBLESHOOTING.md`

## 变更记录
- 见 `docs/CHANGELOG.md`
