#!/usr/bin/env bash
set -Eeuo pipefail

# Capability flags:
#   NEEDS_ARGS    -> hide Run now / dry-run (menu should ask args first)
#   DRYRUN        -> show Run with --dry-run (only if not NEEDS_ARGS)
#   HIDE_PROMPTS  -> hide Run with prompts (keep Run now)

# Registry format:
#   "rel_path|FLAG1,FLAG2,FLAG3"

die() {
  local msg="$*"
  # BASH_SOURCE[1]/LINENO[0] 对应调用 die 的位置
  local src="${BASH_SOURCE[1]:-?}"
  local line="${BASH_LINENO[0]:-?}"
  echo "[ERROR] ${src}:${line} ${msg}" >&2
  exit 1
}

# ---- Global error trap ----
on_err() {
  local ec="$?"
  local src="${BASH_SOURCE[1]:-?}"
  local line="${BASH_LINENO[0]:-?}"
  local cmd="${BASH_COMMAND:-?}"
  echo "[ERROR] ${src}:${line} exited=${ec} cmd=${cmd}" >&2
  exit "$ec"
}
trap on_err ERR


# ---- Capability registry and lookup ----
CAP_REGISTRY=(
  "backup/rsync_backup_final.sh|DRYRUN,HIDE_PROMPTS"
  "backup/rsync_backup.sh|DRYRUN,HIDE_PROMPTS"
  "backup/backup_menu.sh|HIDE_PROMPTS"
  "backup/open_last_snapshot.sh|HIDE_PROMPTS"
  "backup/sync_history.sh|HIDE_PROMPTS"
  "backup/sync_reports.sh|HIDE_PROMPTS"
  "backup/sync_reports_real|HIDE_PROMPTS"
  "backup/sync_reports_real_⚠️delete|HIDE_PROMPTS"
  "novel/novel_crawler.py|HIDE_PROMPTS"
  "novel/novel_novel_crawler.py|HIDE_PROMPTS"
  "disk/ssd_monitor.sh|HIDE_PROMPTS"
  "disk/disk_health_check.sh|HIDE_PROMPTS"
  "media/lyrics_auto_no_vad.sh|NEEDS_ARGS"
  "media/lyrics_import_obsidian.sh|NEEDS_ARGS"
  "doctor/toolbox_doctor.sh|HIDE_PROMPTS"
  "help/open_troubleshooting.sh|HIDE_PROMPTS,HIDE_DRYRUN"
)

cap_get_flags() {
  local rel="$1"
  local row key flags
  for row in "${CAP_REGISTRY[@]}"; do
    key="${row%%|*}"
    [[ "$key" == "$rel" ]] || continue
    flags="${row#*|}"
    # normalize: remove spaces
    flags="${flags//[[:space:]]/}"
    echo "$flags"
    return 0
  done
  echo ""
  return 0
}

cap_has() {
  local rel="$1" flag="$2" flags
  flags="$(cap_get_flags "$rel")"
  [[ -n "$flags" ]] || return 1
  [[ ",${flags}," == *",${flag},"* ]]
}

# ---- Policy helpers (UI should call these, not raw flags) ----
cap_needs_args() {
  local rel="$1"
  cap_has "$rel" "NEEDS_ARGS"
}

cap_show_dryrun() {
  local rel="$1"
  # DRYRUN is UI: show dry-run option only if not NEEDS_ARGS
  cap_has "$rel" "DRYRUN" && ! cap_needs_args "$rel"
}

cap_show_prompts() {
  local rel="$1"
  # show prompts unless explicitly hidden (and unless NEEDS_ARGS forces arg flow)
  ! cap_has "$rel" "HIDE_PROMPTS" && ! cap_needs_args "$rel"
}

cap_show_run_now() {
  local rel="$1"
  # Run now hidden if NEEDS_ARGS
  ! cap_needs_args "$rel"
}

