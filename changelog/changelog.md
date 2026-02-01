#9. changelog update: 重新开始记录changelog [2026-01-31 15:53]
#8. changelog update: lyrics pipeline and ux交互 | files: _lib/rules.sh,_lib/version.sh,changelog/changelog.md,docs/TROUBLESHOOTING_INDEX.md,docs/Troubleshooting.md,scripts/backup/backup_menu.sh,scripts/backup/rsync_backup_final.sh,scripts/backup/sync_reports.sh,scripts/media/lyrics_auto_no_vad.sh,scripts/system/bump_toolbox_version.sh,scripts/toolbox_super_compatible.sh [2026-01-30 07:17]
Changelog（lyrics pipeline / ux 交互）
## Added
* lyrics_auto_no_vad.sh：交互式输入
    * 支持打开 AUDIO_PICK_DIR（Finder）后拖拽音频路径到终端输入（/dev/tty 读取）。
    * 语言只问一次：Lang (en|ja|zh)，生成对应 lyrics_<name>. <lang>.srt.txt。
* 输出落地结构统一
    * 输出目录：$TOOLBOX_DIR/_out/Lyrics/
    * 工作目录：work_lyrics_<NAME>/（含 wav/ txt/ meta.txt segments.tsv silence.txt 等）
* Tips 输出统一
    * 使用 ux_tip/ux_tip_lines（或你现在的 print_lyrics_tips）在结尾提示可复现命令（hybrid/fixed/调阈值）。
* 结束后自动打开输出位置
    * ux_open_after "$OUT" "Lyrics output"（打开输出文件所在的 Lyrics 文件夹/定位文件）
## Changed
* 模式策略：hybrid 为默认
    * silence detect 失败或 segment 太少 → 自动 fallback 到 fixed interval
* 解析与规范化增强
    * normalize_drag_path：去引号、处理 \ 、去 file://
    * normalize_mode/normalize_interval：修复 :hybrid、:12 这种污染输入导致的错误
## Fixed
* set -u 下的 unbound variable
    * 典型：std.sh / log.sh / ux.sh 内部引用 $2、$date 未赋值
    * 修复策略：函数参数统一用 ${1-} ${2-}；需要默认值用 var="${var:-default}"
* read_tty: command not found
    * 原因：脚本加载的不是包含 read_tty 的库（或函数名不一致）
    * 处理：统一在 _lib/ux.sh 提供 ux_read_tty，脚本只调用 ux 层函数
* Unknown mode: :hybrid
    * 原因：wrapper/extra_args 传参带了冒号前缀或拼接残留
    * 处理：m="${m#:}" + lowercase
* ValueError: could not convert string to float ':12'
    * 原因：interval 同样被污染为 :12
    * 处理：interval normalize + 正则校验
#7. This release continues the transition from feature-oriented scripts to a structured, inspectable workflow.
Scripts now primarily express control flow and intent; configuration and behavior are resolved externally. 
Scripts are intentionally thin; be4havior is resolved via loaders and env.| files: _lib/version.sh,changelog/changelog.md,changelog/maintenance/maintenance_template.md
#6. load_conf.sh 作为统一loader/o backup/open_last_snapshot.sh ' now uses LOCAL->NETWORK ->REMOTE flow with atagged logs.'
#5. doctor/toolbox_doctor.sh---hide prompts,change log path | files: _lib/rules.sh,legacy/disk_health_check.sh,scripts/disk/check_disk_health_merged_v2.sh,scripts/doctor/toolbox_doctor_F.sh,scripts/doctor/toolbox_doctor.sh,scripts/toolbox_F.sh,scripts/toolbox_super_compatible.sh
#4. ~/toolbox/_lib/rules.sh---update rules | files: _lib/version.sh,changelog/changelog.md,scripts/disk/disk_health_check.sh
#3. disk/check_disk_health_merged_v2.sh---hide run with prompts | files: _lib/rules.sh
#2. 修改了sync_reports.sh的log路径地址，引入了global env | files: scripts/backup/sync_reports.sh
#1. backup/sync_reports.sh and backup/sync_history.sh---隐藏run with prompts | files: _lib/rules.sh,changelog/changelog.md,scripts/backup/rsync_backup.sh,scripts/backup/rsync_to_imac_ssh.sh
