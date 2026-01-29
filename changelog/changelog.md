#7. This release continues the transition from feature-oriented scripts to a structured, inspectable workflow.
Scripts now primarily express control flow and intent; configuration and behavior are resolved externally. 
Scripts are intentionally thin; behavior is resolved via loaders and env.| files: _lib/version.sh,changelog/changelog.md,changelog/maintenance/maintenance_template.md
#6. load_conf.sh 作为统一loader/o backup/open_last_snapshot.sh ' now uses LOCAL->NETWORK ->REMOTE flow with atagged logs.'
#5. doctor/toolbox_doctor.sh---hide prompts,change log path | files: _lib/rules.sh,legacy/disk_health_check.sh,scripts/disk/check_disk_health_merged_v2.sh,scripts/doctor/toolbox_doctor_F.sh,scripts/doctor/toolbox_doctor.sh,scripts/toolbox_F.sh,scripts/toolbox_super_compatible.sh
#4. ~/toolbox/_lib/rules.sh---update rules | files: _lib/version.sh,changelog/changelog.md,scripts/disk/disk_health_check.sh
#3. disk/check_disk_health_merged_v2.sh---hide run with prompts | files: _lib/rules.sh
#2. 修改了sync_reports.sh的log路径地址，引入了global env | files: scripts/backup/sync_reports.sh
#1. backup/sync_reports.sh and backup/sync_history.sh---隐藏run with prompts | files: _lib/rules.sh,changelog/changelog.md,scripts/backup/rsync_backup.sh,scripts/backup/rsync_to_imac_ssh.sh
