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
ux_open_dir() {
  # ux_open_dir <dir> [msg]
  local dir="${1:-}"
  local msg="${2:-}"

  [[ -n "$dir" ]] || { err "ux_open_dir: missing dir"; return 1; }

  # expand ~
  if [[ "$dir" == "~/"* ]]; then
    dir="$HOME/${dir#~/}"
  elif [[ "$dir" == "~" ]]; then
    dir="$HOME"
  fi

  if [[ ! -d "$dir" ]]; then
    err "Directory not found: $dir"
    return 1
  fi

  [[ -n "$msg" ]] && info "$msg"
  kv "Open" "$dir"

  if command -v open >/dev/null 2>&1; then
    # macOS: force Finder
    open -a Finder "$dir"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
      err "open failed (rc=$rc): $dir"
      return 2
    fi
    return 0
  fi

  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$dir" >/dev/null 2>&1 &
    return 0
  fi

  warn "No opener found (open/xdg-open)."
  return 2
}
# Default prompt device for interactive reads
: "${UX_PROMPT_TTY:=/dev/tty}"

ux_is_tty() {
  # True if stdin+stdout are terminals
  [[ -t 0 ]] && [[ -t 1 ]]
}

ux_has_tty() {
  # True if we can read/write UX_PROMPT_TTY (default /dev/tty)
  [[ -n "${UX_PROMPT_TTY:-}" ]] && [[ -r "${UX_PROMPT_TTY}" ]] && [[ -w "${UX_PROMPT_TTY}" ]]
}

need_tty() {
  # Ensure interactive TTY is available, else exit/return error.
  #
  # Usage:
  #   need_tty              # default message
  #   need_tty "Custom msg" # custom
  #
  # Return codes:
  #   0 ok
  #   2 no tty available
  local msg="${1:-Interactive TTY required (cannot prompt).}"

  if ux_has_tty; then
    return 0
  fi

  # Prefer your ux err/die if present, but keep standalone-safe
  if command -v err >/dev/null 2>&1; then
    err "$msg"
    err "Tip: run in an interactive terminal (not via pipe/cron/CI), or set UX_PROMPT_TTY."
  else
    printf "[ERROR] %s\n" "$msg" >&2
    printf "[ERROR] Tip: run in an interactive terminal (not via pipe/cron/CI), or set UX_PROMPT_TTY.\n" >&2
  fi

  return 2
}
ux_normalize_path() {
  # Normalize paths from drag&drop or user input:
  # - trim spaces
  # - strip surrounding quotes
  # - unescape Finder backslash escapes
  # - expand ~
  local raw="${1-}"
  [[ -n "$raw" ]] || { printf "%s" ""; return 0; }

  # trim
  while [[ "$raw" == " "* ]]; do raw="${raw# }"; done
  while [[ "$raw" == *" " ]]; do raw="${raw% }"; done

  # strip surrounding quotes
  if [[ "$raw" == \"*\" && "$raw" == *\" ]]; then
    raw="${raw#\"}"; raw="${raw%\"}"
  elif [[ "$raw" == \'*\' && "$raw" == *\' ]]; then
    raw="${raw#\'}"; raw="${raw%\'}"
  fi

  # interpret backslash escapes (Finder drag produces \ )
  local path
  path="$(printf '%b' "$raw")"

  # expand ~
  if [[ "$path" == "~/"* ]]; then
    path="$HOME/${path#~/}"
  elif [[ "$path" == "~" ]]; then
    path="$HOME"
  fi

  # drop trailing CR
  path="${path%$'\r'}"

  printf "%s" "$path"
}
info() {
  # info "message..."
  # Prints an INFO line to stdout.
  local msg="$*"
  [[ "${UX_QUIET:-0}" == "1" ]] && return 0

  local prefix='[INFO]'
  local c="${_ux_c_cyan:-}"
  local r="${_ux_c_reset:-}"

  if [[ "${UX_COLOR:-1}" == "1" ]] && [[ -n "$c" ]]; then
    printf "%s%s%s %s\n" "$c" "$prefix" "$r" "$msg"
  else
    printf "%s %s\n" "$prefix" "$msg"
  fi
}


kv() {
  # ux_kv "Key" "Value" [key_width]
  local key="${1:-}"
  local val="${2:-}"
  local w="${3:-14}"

  [[ -z "$key" ]] && return 0

  # Quiet mode: still show key lines? keep consistent with your style
  [[ "${UX_QUIET:-0}" == "1" ]] && return 0

  # pad key
  local pad="$key"
  local klen=${#pad}
  if (( klen < w )); then
    pad="${pad}$(printf '%*s' $((w-klen)) '')"
  fi

  printf "%s: %s\n" "$pad" "$val"
}
ux_log() {
  # ux_log LEVEL MESSAGE...
  #
  # LEVEL: DEBUG|INFO|OK|WARN|ERR
  #
  # Env:
  #   UX_LOG_FILE   : log file path (if empty -> no file logging)
  #   UX_LOG_TS     : 1=timestamp (default 1)
  #   UX_LOG_PID    : 1=include pid (default 0)
  #   UX_LOG_TAG    : tag string (default: basename $0)
  #   UX_LOG_LEVEL  : minimum level to write (DEBUG/INFO/WARN/ERR) default INFO
  #
  local level="${1:-INFO}"; shift || true
  local msg="$*"

  : "${UX_LOG_TS:=1}"
  : "${UX_LOG_PID:=0}"
  : "${UX_LOG_LEVEL:=INFO}"
  : "${UX_LOG_TAG:=$(basename "${0:-shell}")}"

  # --- level gating (file + console) ---
  # order: DEBUG(10) < INFO(20) < OK(20) < WARN(30) < ERR(40)
  local lv_req=20 lv_cur=20
  _ux_level_num() {
    case "$1" in
      DEBUG) echo 10 ;;
      INFO)  echo 20 ;;
      OK)    echo 20 ;;
      WARN)  echo 30 ;;
      ERR)   echo 40 ;;
      *)     echo 20 ;;
    esac
  }
  lv_req="$(_ux_level_num "${UX_LOG_LEVEL}")"
  lv_cur="$(_ux_level_num "${level}")"
  if (( lv_cur < lv_req )); then
    return 0
  fi

  # --- console output (use existing helpers if present) ---
  case "$level" in
    DEBUG) dbg  "$msg" ;;
    INFO)  info "$msg" ;;
    OK)    ok   "$msg" ;;
    WARN)  warn "$msg" ;;
    ERR)   err  "$msg" ;;
    *)     say  "$msg" ;;
  esac

  # --- file output ---
  [[ -n "${UX_LOG_FILE:-}" ]] || return 0

  # ensure parent dir
  local log_dir
  log_dir="$(dirname "$UX_LOG_FILE")"
  [[ -d "$log_dir" ]] || mkdir -p "$log_dir" 2>/dev/null || true

  # timestamp
  local ts=""
  if [[ "${UX_LOG_TS}" == "1" ]]; then
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
  fi

  # pid
  local pid=""
  if [[ "${UX_LOG_PID}" == "1" ]]; then
    pid=" pid=$$"
  fi

  # single-line normalize (avoid breaking log format)
  # (replace CR/LF with \n markers)
  local safe_msg="$msg"
  safe_msg="${safe_msg//$'\r'/\\r}"
  safe_msg="${safe_msg//$'\n'/\\n}"

  # format:
  # 2026-01-31 02:41:03 [INFO] tag=lyrics_auto_no_vad.sh pid=12345 msg=...
  if [[ -n "$ts" ]]; then
    printf "%s [%s] tag=%s%s msg=%s\n" "$ts" "$level" "$UX_LOG_TAG" "$pid" "$safe_msg" >>"$UX_LOG_FILE"
  else
    printf "[%s] tag=%s%s msg=%s\n" "$level" "$UX_LOG_TAG" "$pid" "$safe_msg" >>"$UX_LOG_FILE"
  fi

  return 0
}

ux_pick_file_drag() {
  local prompt="${1:-Path (drag & drop): }"
  local must_exist="${2:-1}"
  local open_dir="${3-}"

  need_tty

  if [[ -n "${open_dir-}" ]]; then
    ux_open_dir "$open_dir" "Opening folder..." || warn "Open folder failed (continuing)."
  fi

  local raw path
  raw="$(ux_read_tty "$prompt" "" 0)" || return $?
  path="$(ux_normalize_path "$raw")"

  if [[ "$must_exist" == "1" ]]; then
    [[ -f "$path" ]] || { err "Not a file: $path"; return 2; }
  fi

  printf "%s" "$path"
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
