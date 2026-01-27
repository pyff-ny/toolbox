README
在其他脚本里怎么用（最小样例）
#!/usr/bin/env bash
set -Eeuo pipefail

TOOLBOX_DIR="${TOOLBOX_DIR:-$HOME/toolbox}"
source "$TOOLBOX_DIR/scripts/_lib/summary.sh"

summary_init
summary_set_meta script_path "$0"
summary_set_meta conf_path  "/Users/jiali/toolbox/conf/backup.env"
summary_set_meta log_abs    "/Users/jiali/toolbox/_out/Logs/rsync_backup_$(date +%F_%H-%M-%S).log"
summary_set_meta remote     "jiali@JiaLis-iMac.local"
summary_set_meta source     "/Users/jiali"
summary_set_meta destination "/Volumes/iMac_HDD_Backup/Macbook/Users/jiali"

summary_set_log_path  "$(echo "$SUMMARY_LOG_ABS")"
summary_set_note_path "/Users/jiali/Obsidian/00_Inbox/backup_runs/rsync_runs.md"

run_mode="REAL"
dry_run=false
summary_begin_run "$run_mode" "$dry_run"

start=$(date +%s)

# 建议：用 wrap_cmd 跑你的 rsync
summary_wrap_cmd rsync -a --delete "/Users/jiali/" "jiali@JiaLis-iMac.local:/dest/path/"
# 这里 SUMMARY_RSYNC_CODE 已经被采集

elapsed=$(( $(date +%s) - start ))
summary_set_metrics "0.00" 0 0 0 "$elapsed" "$(printf '00:00:%02d' "$elapsed")"

summary_finalize
summary_print_end_banner

exit "$SUMMARY_EXIT_CODE"


你现有脚本里已经有 transferred/created/deleted/reg_xfer 的计算逻辑，就把那些值喂给 summary_set_metrics 即可；summary_wrap_cmd 只负责采集退出码，不会干扰你的 rsync 输出。
最关键的“统一点”（防你以后再踩坑）
终端 SUMMARY：code=$SUMMARY_EXIT_CODE
JSON："code": SUMMARY_EXIT_CODE, "rsync_code": SUMMARY_RSYNC_CODE
最终退出：exit "$SUMMARY_EXIT_CODE"