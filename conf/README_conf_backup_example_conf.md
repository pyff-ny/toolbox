# conf/backup.example.conf
# Copy to ops/backup.conf and edit values.
# DO NOT commit real configs.

SRC_DIR="$HOME/data"
DST_DIR="/Volumes/BackupDisk/data"
RSYNC_FLAGS="-aH --delete --info=stats2"
