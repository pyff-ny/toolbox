# Ops 小作品集（macOS）

这份目录记录了我在 macOS 上完成的两个“小型运维项目”，用于提升系统管理能力与面试可讲述的实践经验：

1) Disk Health Check（读硬盘数据/健康巡检）  
2) Rsync Backup over SSH（备份硬盘数据/镜像备份）

---

## 项目 1：Disk Health Check（硬盘健康巡检）

### 目标
- 枚举所有 physical 磁盘（内置/外置）
- 对指定磁盘执行健康检查并生成可追溯输出：日志、报告、原始证据
- 内置 SSD 支持解析 SMART/NVMe 指标（若设备支持，如温度、Unsafe Shutdowns、寿命百分比等）
- 外置 HDD 如果 USB 桥接不透传 SMART，明确归因并输出 UNSUPPORTED（不误判、不瞎折腾）

### 路径
- 项目目录：`~/Ops/disk-health/`
- 主脚本：`~/Ops/disk-health/bin/check_disk_health.sh`
- 文档：`~/Ops/disk-health/docs/README.md`
- 日志：`~/Ops/disk-health/logs/`
- 报告：`~/Ops/disk-health/reports/`
- 证据：`~/Ops/disk-health/logs/smartctl_*_*.out`（smartctl 原始输出）

### 常用命令
列出硬盘：
```bash
~/Ops/disk-health/bin/check_disk_health.sh --list
```
## 交互选择
```bash
~/Ops/disk-health/bin/check_disk_health.sh
```

## 直接检查（推荐）：
```bash
~/Ops/disk-health/bin/check_disk_health.sh --device /dev/disk0
```
---
# 项目 2：Rsync Backup over SSH（rsync + SSH 镜像备份）
## 目标
* 从 MacBook 通过 SSH/rsync 备份到 iMac 外置硬盘
* 支持 dry-run 审查、排除策略加速、删除保护（backup-dir 回收站）
* 全程日志可追溯，便于排障与复盘
## 路径
* 项目目录：~/Ops/rsync-backup/
* 主脚本：~/Ops/rsync-backup/bin/rsync_backup.sh
* 配置：~/Ops/rsync-backup/conf/
* 文档：~/Ops/rsync-backup/docs/README.md
* 日志：~/Ops/rsync-backup/logs/
* 常用命令
* Dry-run（先审查，不改动）：
```bash
  ~/Ops/rsync-backup/bin/rsync_backup.sh --dry-run
```
## 正式执行

```bash
~/Ops/rsync-backup/bin/rsync_backup.sh

```
## 推荐的最终 SUMMARY 格式（用于工具化输出）
```bash
SUMMARY | status=<OK/WARN/ERROR> | code=<0/24/23/...> | dry_run=<true/false> | transferred=<MB> | reg_xfer=<N> | created=<N> | deleted=<N> | elapsed=<HH:MM:SS> | remote=<user@host> | trash=<path or N/A> | log=<rsync_backup_*.log>
```

# 示例输出（可用于面试展示）
## Disk Health Check（外置盘 SMART 不透传示例）
```bash
## Summary
- Status: UNSUPPORTED (SMART passthrough unavailable via USB bridge)
- Device: /dev/diskX (external, physical)
- Checked on: 2026-01-12
```
## 说明：
* 这是典型的 USB 桥接限制：文件访问正常，但 SMART（温度/坏扇区/通电小时等）无法透传到 macOS。
* 处理策略：保留证据日志；转用文件层校验（hash/rsync 校验）或更换支持 SMART passthrough 的硬件链路。

# Rsync Backup（真实执行增量同步示例）
```bash
Number of files: 85,862 (reg: 75,088, dir: 9,861, link: 912, special: 1)
Number of created files: 11 (reg: 11)
Number of deleted files: 10 (reg: 8, dir: 2)
Number of regular files transferred: 151
Total file size: 12.73G bytes
Total transferred file size: 63.84M bytes
Literal data: 25.42M bytes
Matched data: 38.44M bytes
Total bytes sent: 29.04M
Total bytes received: 235.01K
total size is 12.73G  speedup is 434.83
```
## 解读要点：
* 这是一次增量同步：全量 12.73G 的数据集中，实际需要同步的是 63.84MB。
* 创建 11 个文件、删除 10 个对象，说明镜像保持一致且改动受控。
* Matched data 表示 rsync 利用差异匹配避免重复传输，提高效率（speedup=434.83）。

# 面试讲法（30 秒）
## 我在 macOS 上做了两个运维型小项目：
* 1）磁盘健康巡检工具：支持列出内外置物理盘，生成日志/报告/原始证据；内置 SSD 可解析关键 SMART 指标；外置盘若 USB 桥接不透传 SMART，可清晰归因并提供替代方案。
* 2）rsync+SSH 备份系统：支持 dry-run 审查、误删保护（backup-dir 回收站）、排除策略提升速度、全程日志可追溯，最终形成可重复、可审计的备份流程。


