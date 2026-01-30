#!/usr/bin/env bash
set -Eeuo pipefail

# ux.sh: interactive helpers (tty-safe)
# Requires: log.sh (die/log_info/log_warn/...)

# Read one line from /dev/tty (safe under fzf / piped stdio)
ux_read_tty() {
  local prompt="${1:-}"
  local out=""
  [[ -n "$prompt" ]] && printf "%s" "$prompt" >/dev/tty
  IFS= read -r out </dev/tty || return 1
  printf "%s" "$out"
}

ux_trim() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "$s"
}

# Generic: read with default; if var already provided, do not prompt.
# usage: val="$(ux_get_default "$existing" "Prompt: " "default")"
ux_get_default() {
  local existing="${1-}"
  local prompt="${2-}"
  local def="${3-}"

  if [[ -n "${existing}" ]]; then
    printf "%s" "${existing}"
    return 0
  fi

  local v=""
  v="$(ux_read_tty "$prompt")" || return 1
  v="$(ux_trim "$v")"
  [[ -n "$v" ]] || v="$def"
  printf "%s" "$v"
}

# Choose a file (parameter > drag input > optional dialog)
# usage: f="$(ux_get_file "$incoming" "$default_dir" "Audio file path (drag here, Enter to choose): ")"
ux_get_file() {
  local incoming="${1-}"
  local default_dir="${2:-$HOME}"
  local prompt="${3:-File path (drag here, Enter to choose): }"

  local p=""
  p="$(ux_trim "$incoming")"

  # 1) already provided
  if [[ -n "$p" ]]; then
    [[ -f "$p" ]] || die "File not found: $p"
    printf "%s" "$p"
    return 0
  fi

  # 2) ask user to drag
  echo "$prompt" >/dev/tty
  if ! IFS= read -r p </dev/tty; then
    return 1
  fi
  p="$(ux_trim "$p")"

  # 3) Enter => dialog (macOS)
  if [[ -z "$p" ]]; then
    p="$(osascript <<EOF
set defaultFolder to POSIX file "$default_dir"
set f to choose file with prompt "Choose a file" default location defaultFolder
POSIX path of f
EOF
)" || return 1
    p="$(ux_trim "$p")"
  fi

  [[ -n "$p" ]] || return 1
  [[ -f "$p" ]] || die "File not found: $p"
  printf "%s" "$p"
}

# Confirm dangerous actions (DELETE). Two-step: type YES, then "press Enter to continue".
# Returns 0 if confirmed, 1 otherwise.
ux_confirm_delete() {
  local prompt="${1:-Type YES to confirm DELETE: }"
  local ans=""

  ans="$(ux_read_tty "$prompt")" || return 1
  ans="$(ux_trim "$ans")"
  [[ "$ans" == "YES" ]] || return 1

  log_warn "LOCALLY" "DELETE confirmed by user input"
  ux_read_tty "Press ENTER to continue (Ctrl+C to abort)..." >/dev/tty || true
  return 0
}

# Read a line from TTY (safe under fzf / redirected stdin)
read_tty() {
  local prompt="${1-}"
  local out=""
  printf "%s" "$prompt" >/dev/tty
  IFS= read -r out </dev/tty || return 1
  printf "%s" "$out"
}
