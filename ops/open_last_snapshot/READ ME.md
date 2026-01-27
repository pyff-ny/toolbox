READ ME

目标：读取本地 snapshot_index.tsv 最后一条记录 → 如果 DRY_RUN=true 就只提示+打开本地 log → 否则正常 open 本地目录 & ssh 打开 iMac 快照目录。

你会得到的效果
DRY_RUN=true
不再提示 “目录不存在”
不再 SSH 打开 iMac
只会打开本地 log（如果存在）
DRY_RUN=false
自动打开 log
自动打开本地快照目录（存在就直接开）
只有当本地快照目录不存在 才会 ssh 去 iMac 打开（避免重复弹窗）