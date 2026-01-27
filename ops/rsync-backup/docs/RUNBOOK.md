# RUNBOOK - 运行手册（rsync 镜像备份）

## 运行前 Checklist（每次 2 分钟）
- [ ] iMac 开启 Remote Login（SSH）
- [ ] DEST_HOST 可解析（优先 `<LocalHostName>.local`，必要时用固定 IP）
- [ ] 远端目录可写：`${REMOTE_DEST_PATH}`（外置盘挂载正常）
- [ ] 确认本次允许 `--delete`（镜像模式会删除远端多余文件）
- [ ] 如刚改过 excludes/路径：建议先启用“删除保护”（见下）

## Step 1：Dry-run（必做）
命令：
- `bin/backup.sh --dry-run`

目标：
- 观察将要 *create / transfer / delete* 的规模
- 特别关注删除列表（*deleting）

删除清单（建议保存证据）：
- `bin/backup.sh --dry-run | grep '^\*deleting' > reports/deletes_$(date +%F_%H%M).txt`

快速看前 50 条：
- `bin/backup.sh --dry-run | grep '^\*deleting' | head -n 50`

## Step 2：Real run（正式执行）
命令：
- `bin/backup.sh`

运行注意：
- 建议在执行期间保持 Mac 不休眠（你脚本已用 caffeinate）
- 首次全量或大量改动后会慢；日常增量应明显快

## Step 3：Post-run 验收（专业必做，5 分钟）
- [ ] 查看最新日志（logs/）确认 rsync code：
  - `0`：OK
  - `24`：vanished file（常见于缓存/缩略图变化；若发生在核心目录需处理）
  - `23`：partial transfer（需排错）
- [ ] 再跑一次 dry-run：应接近“无变化”
  - `bin/backup.sh --dry-run`
- [ ] 抽样校验 3 个关键文件（见 RESTORE 的 Verify 段）
- [ ] 每月至少做一次“恢复演练”（恢复一个小目录到本机临时位置）

## 推荐策略（降低误删风险）
### 方案 A：先不删（新环境/大改动推荐）
- 暂时禁用 `--delete`（或做一个 `--no-delete` 开关）
- 先把缺失内容补齐，对齐后再开启 delete 收敛

### 方案 B：删除保护（强烈推荐）
在 rsync 参数中增加：
- `--backup --backup-dir="<remote>/.rsync-trash/<timestamp>"`
这样即使误删，也能从远端 `.rsync-trash/` 回滚。
