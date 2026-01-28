#!/usr/bin/env bash
set -Eeuo pipefail
#以后加功能：只需要在 CAP_REGISTRY+=(...) 增加一行，不改 menu_actions 代码
# Capability flags:
#   NEEDS_ARGS    -> hide Run now / dry-run
#   DRYRUN        -> show Run with --dry-run (only if not NEEDS_ARGS)
#   HIDE_PROMPTS  -> hide Run with prompts (keep Run now)
#
# Registry format:
#   "rel_path|FLAG1,FLAG2,FLAG3"

CAP_REGISTRY=(
  "backup/rsync_backup_final.sh|DRYRUN,HIDE_PROMPTS"
  "backup/backup_menu.sh|HIDE_PROMPTS"
  "backup/open_last_snapshot.sh|HIDE_PROMPTS"
  "novel/novel_crawler.py|HIDE_PROMPTS"
  "novel/novel_novel_crawler.py|HIDE_PROMPTS"
  "disk/check_disk_health.sh|HIDE_PROMPTS"

  "media/lyrics_auto_no_vad.sh|NEEDS_ARGS"
  "media/lyrics_import_obsidian.sh|NEEDS_ARGS"
)


cap_get_flags() {
  local rel="$1"
  local row
  for row in "${CAP_REGISTRY[@]}"; do
    local key="${row%%|*}"
    local flags="${row#*|}"
    [[ "$key" == "$rel" ]] && { echo "$flags"; return 0; }
  done
  echo ""
  return 0
}

# Check if a capability flag is set for a given rel path
cap_has() {
  local rel="$1"
  local flag="$2"
  local flags
  flags="$(cap_get_flags "$rel")"
  flags="${flags//[[:space:]]/}" # remove spaces
  [[ ",${flags}," == *",${flag},"* ]]
}


