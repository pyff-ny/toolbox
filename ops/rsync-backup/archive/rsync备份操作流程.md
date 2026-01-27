## 把“报错行”完整打到日志里（你下一步就能看到原因）(每次--dry-run)
```
DEST="/Volumes/iMac_HDD_Backup/SSD_System_Data/"
mkdir -p "$DEST"
LOG="$HOME/Logs/rsync_run.log"
mkdir -p "$HOME/Logs"

sudo rsync -aHAXx --numeric-ids --delete --info=stats2,progress2 --dry-run \
  --exclude="/private/var/folders/**" \
  --exclude="/private/var/vm/**" \
  --exclude="/private/var/db/**" \
  --exclude="/Library/Caches/**" \
  --exclude="/private/var/networkd/**" \
  --exclude="/private/var/protected/**" \
  --exclude="/.Spotlight-V100/**" \
  --exclude="/.Trashes/**" \
  --exclude="/private/var/tmp/**" \
  "/System/Volumes/Data/" \
  "$DEST/" \
  2>&1 | tee "$LOG"

# 另开一个终端窗口
tail -f "$HOME/Logs/rsync_run.log"
```

---
## 然后看错误文件（通常这里就有答案）：
```
ls -1 "$LOG"
tail -n 80 "$LOG"
```
## 以及在log里搜关键字：
``` 
egrep -n "denied|not permitted|operation not permitted|xattr|acl|failed|error|vanished" \
  "$LOG" | tail -n 80

```
