#!/usr/bin/env bash

TOOLBOX_VERSION="2026-01-29.1715"

#==============
#18. 修改了open_last_snapshot.sh中环境变量加载方式，改为从global.env加载。
#17. 修复了rules.sh中backup/open_last_snapshot.sh的HIDE_PROMPTS标记。
#16. 修改了wifiwach保存的log路径，统一到toolbox/_out/Logs下。
#15. 修复了toolbox_super_compatible.sh中run_cmd函数的调试输出问题。
#14. 在rsync_backup_log_config.sh中，日志路径统一到toolbox/_out/Logs下。
#13. 在global.env和net.env中，新增LOG_DIR变量，统一日志目录到toolbox/_out/Logs。
#12. 修复了run_cmd_fixed.sh中调试输出的问题。
#11. 在rules.sh中，新增了backup/open_last_snapshot.sh的HIDE_PROMPTS标记。
#10. 修复了wifi_watch.sh中日志路径的问题。
#9. 统一了wifi_watch.sh中日志路径的设置。
#8. 修复了toolbox_super_compatible.sh中run_cmd函数的调试输出问题。
#7. 在conf/net.env中，新增LOG_DIR变量，统一日志目录到toolbox/_out/Logs。
#6. 统一了wifi_watch.sh中日志路径的设置。
#5. 修复了wifi_watch.sh中日志路径的问题。
#4. 在conf/global.env中，新增LOG_DIR变量，统一日志目录到toolbox/_out/Logs。
#3. 在rsync_backup_log_config.sh中，日志路径统一到toolbox/_out/Logs下。
#2. 修复了toolbox_super_compatible.sh中run_cmd函数的调试输出问题。
#1. 修复了rules.sh中backup/open_last_snapshot.sh的HIDE_PROMPTS标记。
#==============
