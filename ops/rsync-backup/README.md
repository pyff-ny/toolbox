README.md

# 备份源Documents文件夹到外置硬盘iMac_HDD_Backup/imac_rsync_Backup
## 脚本里面有 `--delete`,这个会删除目的文件夹的文件，小心使用！
## 脚本排除了一些文件，比如 .DS_Store, .git, .tmp等文件
# 赋予执行权限
* 批量修改：在 2026 年，如果你管理的是 macOS Sequoia 或更高版本的系统，当你为脚本添加权限时，建议使用` chmod +x *.sh` ，这依然是最标准的做法
```
chmod +x /路径/到/你的/backup.sh
```
# 运行脚本

```

#我这个命令提示 permission denied，terminal处于当前backup.sh所在的文件夹
./backup.sh
```

![](./Screenshot%202026-01-09%20at%206.10.51%20PM.png)

我又用了sudo，`sudo ./backup.sh` ,但还是不行，提示我 `command not found`

## update"
` sudo ./backup.sh` 是可行的，在文件所在的文件夹里;
` ./backup.sh` 也可以，但是报错说 permission denied,最好还是用 `sudo ./backup.sh `
## at last
```
sudo sh ./backup.sh

```
this worked!
