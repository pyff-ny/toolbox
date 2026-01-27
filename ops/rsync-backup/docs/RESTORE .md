# RESTORE - 恢复手册

## 基本原则（最重要）
1. **先恢复到临时目录验证**，再覆盖回原位置
2. 如你使用了 `--delete` 镜像同步：误删会同步到远端，所以更要依赖：
   - 删除保护（--backup-dir）
   - 另一份离线备份
   - 恢复演练

## 恢复单个文件夹（推荐方式）
示例：从远端恢复一个目录到本机临时目录：
```bash
mkdir -p "$HOME/RestoreTest"
rsync -aHAX --info=progress2 \
  "${DEST_USER}@${DEST_HOST}:${REMOTE_DEST_PATH}/Users/${USER}/Documents/SomeFolder/" \
  "$HOME/RestoreTest/SomeFolder/"

```

## 确认无误后，再覆盖回原位置（谨慎）：
``` bash
rsync -aHAX --info=progress2 \"$HOME/RestoreTest SomeFolder/" \"$HOME/Documents/SomeFolder/"
```

## 恢复单个文件（示例）
```bash
rsync -aHAX --info=progress2 \
  "${DEST_USER}@${DEST_HOST}:${REMOTE_DEST_PATH}/Users/${USER}/Documents/report.pdf" \
  "$HOME/RestoreTest/report.pdf"
```

## 校验（Verify）
* 抽样 hash 校验（推荐）
* 本机：
```bash
shasum -a 256 "/path/to/file"
```
* 远端
```bash
ssh "${DEST_USER}@${DEST_HOST}" "shasum -a 256 '${REMOTE_DEST_PATH}/Users/${USER}/path/to/file'"
```
hash 一致---->内容一致

---
# 如果启用了删除保护（--backup-dir）
* 远端会出现类似：
  * ` ${REMOTE_DEST_PATH}/.rsync-trash/2026-01-11_1900/... `
  * 从这里把误删文件rsync回来即可
  
# 假设你误删了 Documents/Resume.pdf，它会在回收站保留类似路径：
```swift
.../.rsync-trash/2026-01-11_190012/Users/<user>/Documents/Resume.pdf
```
* 你可以从远端把它rsync回来（示例）：
  
```bash
rsync -aHAX --info=progress2 \
  "user@imac:/Volumes/iMac_HDD_Backup/Macbook/.rsync-trash/2026-01-11_190012/Users/$USER/Documents/Resume.pdf" \
  "$HOME/RestoreTest/Resume.pdf"
```
‼️⏰⚠️：
**这不是版本控制：它只保存“本次运行中被删/被覆盖”的旧文件**
**仍然建议：删前审查**
* 你现在的 --dry-run + --itemize-changes 依然要保留，这是第一道防线；--backup-dir 是第二道保险


```yaml

---

## 4）docs/TROUBLESHOOTING.md（排错手册）
```markdown
# TROUBLESHOOTING - 常见问题与处理

## Exit code 24: vanished file
### 症状
- rsync 返回 code 24
- 日志里出现 vanished file / file disappeared

### 原因
- 扫描/传输期间文件被系统或应用改动（缓存、缩略图、FileProvider 最常见）

### 处理
- 把高变化目录加入 excludes（缓存、缩略图）
- 核心目录（Documents/Desktop 等）若频繁出现：关闭相关应用后重跑

### 是否可接受
- 仅发生在缓存/缩略图：通常可接受
- 发生在核心数据：不可接受，需排除根因

---

## Exit code 23: partial transfer
### 症状
- 退出码 23，可能伴随 Permission denied / I/O error

### 处理
- 查看日志中第一条关键错误（往上找 Permission denied / No such file）
- 确认远端磁盘挂载、路径可写
- 如需要远端 sudo（仅限目标路径需要管理员权限时）：
  - 设置 REMOTE_SUDO=true 并确保 sudo -n 可用（避免交互卡死）

---

## Permission denied (13)
### 原因
- 系统保护目录、容器目录、或远端目录权限不足

### 处理
- 优先：精准 excludes 问题子目录（别一刀切排除 Documents）
- 检查远端目录权限：test -w
- 必要时更换 REMOTE_DEST_PATH 到可写位置

---

## 速度突然很慢（2MB/s）
### 常见原因
- 大量小文件（IOPS 瓶颈）
- 目标盘为 HDD、或目标盘繁忙
- 同步了缩略图/缓存（文件量巨大且高变化）

### 优化
- 精准排除 thumbnails/caches/FileProvider
- 减少 `-H`（硬链接）或避免 `--checksum`（若你启用了的话）
- 优先走有线网络或同网段稳定 Wi-Fi

---

## 删除量异常大
### 处理步骤（务必按顺序）
1. 先停：只做 dry-run
2. 输出删除清单：grep '*deleting'
3. 检查 excludes/SRC 基准路径是否正确
4. 必要时启用删除保护 `--backup --backup-dir`
```