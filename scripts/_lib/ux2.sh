#!/usr/bin/env bash
# _lib/ux.sh
# UX primitives: tty-based, cancel-aware, set -u safe.
# UX primitives:
# - read_tty    : read single-line input from /dev/tty
# - confirm     : yes/no confirmation
# - choose      : numbered choice
# - ux_tip      : post-run next-step hints (no control flow)
# - ux_open_after: open result after success (Finder)
#
# Rules:
# - ux_tip is ONLY used at completion stage
# - ux_* functions never exit or change return codes
#Toolbox UX 规范 v1.0（_lib/ux.sh）
#0. 总原则（必须遵守）
#交互只从 /dev/tty 读写
#目的：fzf / 管道 / wrapper 场景稳定，不被 stdin 污染。
#禁止：裸 read（除非明确 </dev/tty）
#CLI 参数优先，交互兜底
#顺序：positional/flags → env default → interactive prompt → cancel
#目的：脚本可自动化 + 可交互，二者兼容。
#ux_ 不改变控制流*
#ux_tip / ux_open_after：只打印/执行辅助动作，不应该 exit，不改变返回码。
#会改变控制流的只允许：die / 调用者显式判断返回值。
#取消是正常路径，不是错误
#用户取消：返回 1 或 130（如果是 Ctrl+C），并由上层打印 [WARN][cancelled] 即可。
#不要把取消当作 [ERROR]。
#set -u 下任何变量读写都要安全
#所有函数入参用 "${1-}"
#读取可选变量用 "${VAR-}" / "${VAR:-default}"
#禁止直接 $2 $3（你之前的 std.sh line 9: $2 unbound 就是这个
#!/usr/bin/env bash
# ux.sh - Toolbox UX helpers (messages, prompts, formatting)
# Usage: source "/path/to/ux.sh"
# Shell: bash 3.2+ (macOS default) compatible

set -u

# -------------------------
# Config toggles (env)
# -------------------------
: "${UX_COLOR:=1}"          # 1=colored, 0=plain
: "${UX_EMOJI:=0}"          # 1=add emoji, 0=none
: "${UX_QUIET:=0}"          # 1=less output
: "${UX_DEBUG:=0}"          # 1=debug prints
: "${UX_SPINNER:=0}"        # 1=enable spinner wrapper
: "${UX_PROMPT_TTY:=/dev/tty}"  # prompt device

# -------------------------
# Internals
# -------------------------
_ux_is_tty() { [[ -t 1 ]] && [[ -t 0 ]]; }
_ux_has_tty() { [[ -r "${UX_PROMPT_TTY}" ]] && [[ -w "${UX_PROMPT_TTY}" ]]; }

# ANSI colors (guarded)
_ux_c_reset=""; _ux_c_dim=""; _ux_c_red=""; _ux_c_green=""; _ux_c_yellow=""; _ux_c_blue=""; _ux_c_cyan=""
if [[ "${UX_COLOR}" == "1" ]] && _ux_is_tty; then
  _ux_c_reset=$'\033[0m'
  _ux_c_dim=$'\033[2m'
  _ux_c_red=$'\033[31m'
  _ux_c_green=$'\033[32m'
  _ux_c_yellow=$'\033[33m'
  _ux_c_blue=$'\033[34m'
  _ux_c_cyan=$'\033[36m'
fi
ux_read_tty() {
  # ux_read_tty "Prompt: " ["default"] [allow_empty:0/1]
  local prompt="${1:-}"
  local def="${2-}"
  local allow_empty="${3:-0}"

  need_tty
  local ans=""
  if [[ -n "${def-}" ]]; then
    ans="$(_read_tty "${prompt}")"
    [[ -z "$ans" ]] && ans="$def"
  else
    ans="$(_read_tty "${prompt}")"
  fi

  if [[ "$allow_empty" != "1" ]] && [[ -z "$ans" ]]; then
    err "Empty input."
    return 1
  fi

  printf "%s" "$ans"
  return 0
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

ux_pick_file_drag() {
  # ux_pick_file_drag "Prompt" [must_exist:0/1] [open_dir]
  local prompt="${1:-Audio file path (drag here): }"
  local must_exist="${2:-1}"
  local open_dir="${3-}"

  need_tty

  if [[ -n "${open_dir-}" ]]; then
    ux_open_dir "$open_dir" "Opening folder for picking..."
  fi

  local raw
  raw="$(ux_read_tty "$prompt" "" 0)" || return $?

  local path
  path="$(ux_normalize_path "$raw")"

  if [[ "$must_exist" == "1" ]]; then
    [[ -e "$path" ]] || { err "Not found: $path"; return 2; }
    [[ -f "$path" ]] || { err "Expected file, got non-file: $path"; return 3; }
  fi

  printf "%s" "$path"
  return 0
}

# -------------------------
# Public functions
# -------------------------
#展示函数：显示将要运行的子脚本信息
ux_show_subscript() {
  # Show which sub-script is about to run
  # Usage: ux_show_subscript "$script_path" ["$display_name"]
  local script_path="${1:-}"
  local display_name="${2:-}"

  [[ -n "$script_path" ]] || return 0

  local bn rel abs
  bn="$(basename "$script_path")"

  # abs: try best
  if command -v realpath >/dev/null 2>&1; then
    abs="$(realpath "$script_path" 2>/dev/null || echo "$script_path")"
  else
    abs="$script_path"
  fi

  # rel: if TOOLBOX_DIR/SCRIPTS_DIR known, compute a nicer relative label
  rel="$script_path"
  if [[ -n "${SCRIPTS_DIR:-}" ]] && [[ "$abs" == "$SCRIPTS_DIR/"* ]]; then
    rel="${abs#"$SCRIPTS_DIR"/}"
  elif [[ -n "${TOOLBOX_DIR:-}" ]] && [[ "$abs" == "$TOOLBOX_DIR/"* ]]; then
    rel="${abs#"$TOOLBOX_DIR"/}"
  fi

  section "RUN TARGET"
  kv "Script" "${display_name:-$bn}"
  kv "Rel" "$rel"
  kv "Path" "$abs"
}


ux_open_after() {
  # Open folder in Finder after success
  # Usage: ux_open_after "/path/to/folder_or_file"
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    warn "ux_open_after: no target specified"
    return 1
  fi
  if [[ ! -e "$target" ]]; then
    warn "ux_open_after: target not found: $target"
    return 1
  fi
  if command -v open >/dev/null 2>&1; then
    open "$target"
    ok "Opened in Finder: $target"
  else
    warn "ux_open_after: 'open' command not found"
    return 1
  fi
}

uux_open_dir() {
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
ux_tip() {
  # ux_tip "message"
  local msg="${1:-}"
  [[ -n "$msg" ]] || return 0
  section "TIP"
  printf "%s\n" "$msg"
}

#打卡文件夹
ux_pick_file_drag() {
  # Drag-and-drop file picker for terminal.
  #
  # Usage:
  #   f="$(ux_pick_file_drag "Drag a file here" 1)" || exit 1
  #   echo "Picked: $f"
  #
  # Args:
  #   $1: prompt text (optional)
  #   $2: must_exist (1 default, 0 allow non-existent)
  #
  # Output:
  #   prints resolved path to stdout
  # Return:
  #   0 ok, 1 cancel/empty, 2 not exist, 3 not a file, 4 other
  #
  local prompt="${1:-Drag a file into this terminal and press Enter}"
  local must_exist="${2:-1}"

  need_tty

  info "$prompt"
  local raw=""
  raw="$(_read_tty "Path (drag & drop): ")"

  # Empty => cancel
  if [[ -z "${raw}" ]]; then
    warn "No input. Cancelled."
    return 1
  fi

  # Trim leading/trailing whitespace (bash-safe)
  # (avoid external sed; minimal)
  while [[ "${raw}" == " "* ]]; do raw="${raw# }"; done
  while [[ "${raw}" == *" " ]]; do raw="${raw% }"; done

  # Remove surrounding quotes if any: "..." or '...'
  if [[ "${raw}" == \"*\" && "${raw}" == *\" ]]; then
    raw="${raw#\"}"; raw="${raw%\"}"
  elif [[ "${raw}" == \'*\' && "${raw}" == *\' ]]; then
    raw="${raw#\'}"; raw="${raw%\'}"
  fi

  # Finder drag usually escapes spaces like "\ "
  # Convert backslash-escaped sequences to literal characters.
  # We use printf '%b' to interpret backslash escapes safely.
  local path=""
  path="$(printf '%b' "${raw}")"

  # Expand ~ if present at beginning
  if [[ "${path}" == "~/"* ]]; then
    path="${HOME}/${path#~/}"
  elif [[ "${path}" == "~" ]]; then
    path="${HOME}"
  fi

  # Remove trailing carriage return if any (rare)
  path="${path%$'\r'}"

  # Validate
  if [[ "${must_exist}" == "1" ]]; then
    if [[ ! -e "${path}" ]]; then
      err "Not found: ${path}"
      return 2
    fi
    if [[ -d "${path}" ]]; then
      err "Expected a file, got a directory: ${path}"
      return 3
    fi
  fi

  printf "%s" "${path}"
  return 0
}

# 删除 wrapper 脚本
ux_confirm_delete() {
  # Strong confirmation gate for destructive deletes.
  #
  # Usage:
  #   ux_confirm_delete "Delete /path/to/file ?" "/path/to/file"
  #   ux_confirm_delete "Proceed with rsync --delete ?" "rsync --delete ..."
  #
  # Returns:
  #   0 -> confirmed (safe to execute delete)
  #   1 -> not confirmed (do not delete)
  #
  # Env:
  #   UX_DELETE_TOKEN: static token (default: DELETE)
  #   UX_DELETE_REQUIRE_YES: 1=need y/yes first (default: 1)
  #
  local title="${1:-Confirm delete}"
  local target="${2:-}"

  : "${UX_DELETE_TOKEN:=DELETE}"
  : "${UX_DELETE_REQUIRE_YES:=1}"

  # Always require TTY for destructive confirmation
  need_tty

  section "DESTRUCTIVE ACTION"
  warn "$title"
  [[ -n "$target" ]] && kv "Target" "$target"
  warn "This will permanently delete data (cannot be undone)."

  # Step 1: yes/no gate
  if [[ "${UX_DELETE_REQUIRE_YES}" == "1" ]]; then
    if ! confirm "Type yes to continue"; then
      warn "Delete cancelled."
      return 1
    fi
  fi

  # Step 2: token gate
  local token="$UX_DELETE_TOKEN"
  # Optional: make token more explicit when target is present
  # token="DELETE" is simplest & reliable; user asked for extra manual input.
  local ans=""
  ans="$(_read_tty "Final confirmation: type '${token}' to DELETE: ")"

  if [[ "$ans" != "$token" ]]; then
    err "Token mismatch. Expected '${token}', got '${ans:-<empty>}'"
    warn "Delete cancelled."
    return 1
  fi

  ok "Delete confirmed."
  return 0
}

_ux_prefix() {
  # $1=level
  local lvl="$1"
  local emoji=""
  if [[ "${UX_EMOJI}" == "1" ]]; then
    case "$lvl" in
      INFO) emoji="ℹ️ " ;;
      OK)   emoji="✅ " ;;
      WARN) emoji="⚠️ " ;;
      ERR)  emoji="❌ " ;;
      DBG)  emoji="🐛 " ;;
      *)    emoji="" ;;
    esac
  fi
  printf "%s" "${emoji}[$lvl]"
}

_ux_print() {
  # $1=color $2=level $3=message (rest)
  local color="$1"; shift
  local lvl="$1"; shift
  local msg="$*"

  [[ "${UX_QUIET}" == "1" ]] && [[ "$lvl" != "ERR" ]] && return 0

  case "$lvl" in
    INFO) printf "%s%s%s %s\n" "$color" "$(_ux_prefix INFO)" "$_ux_c_reset" "$msg" ;;
    OK)   printf "%s%s%s %s\n" "$color" "$(_ux_prefix OK)"   "$_ux_c_reset" "$msg" ;;
    WARN) printf "%s%s%s %s\n" "$color" "$(_ux_prefix WARN)" "$_ux_c_reset" "$msg" >&2 ;;
    ERR)  printf "%s%s%s %s\n" "$color" "$(_ux_prefix ERR)"  "$_ux_c_reset" "$msg" >&2 ;;
    DBG)  printf "%s%s%s %s\n" "$color" "$(_ux_prefix DBG)"  "$_ux_c_reset" "$msg" >&2 ;;
    *)    printf "%s\n" "$msg" ;;
  esac
}

# -------------------------
# Public: logging helpers
# -------------------------
say()  { _ux_print ""   "INFO" "$*"; }
info() { _ux_print "$_ux_c_cyan"   "INFO" "$*"; }
ok()   { _ux_print "$_ux_c_green"  "OK"   "$*"; }
warn() { _ux_print "$_ux_c_yellow" "WARN" "$*"; }
err()  { _ux_print "$_ux_c_red"    "ERR"  "$*"; }
dbg()  { [[ "${UX_DEBUG}" == "1" ]] && _ux_print "$_ux_c_dim" "DBG" "$*"; return 0; }

die() {
  # die "message" [exit_code]
  local m="${1:-}"
  local code="${2:-1}"
  [[ -n "$m" ]] && err "$m"
  exit "$code"
}

# -------------------------
# Public: formatting helpers
# -------------------------
hr() {
  local ch="${1:--}"
  local n="${2:-60}"
  local line=""
  while (( ${#line} < n )); do line="${line}${ch}"; done
  printf "%s\n" "$line"
}

section() {
  # section "Title"
  local t="$*"
  hr
  printf "%s%s%s\n" "$_ux_c_blue" "$t" "$_ux_c_reset"
  hr
}

kv() {
  # kv "Key" "Value"
  local k="${1:-}"; local v="${2:-}"
  printf "%s: %s\n" "$k" "$v"
}

bullet() {
  # bullet "text"
  printf " - %s\n" "$*"
}

# -------------------------
# Public: prompt helpers (TTY-safe)
# -------------------------
_read_tty() {
  # Read from /dev/tty to avoid fzf/trap stdin issues
  local prompt="$1"
  local out=""
  if _ux_has_tty; then
    printf "%s" "$prompt" >"${UX_PROMPT_TTY}"
    IFS= read -r out <"${UX_PROMPT_TTY}" || true
  else
    # fallback: stdin
    printf "%s" "$prompt" >&2
    IFS= read -r out || true
  fi
  printf "%s" "$out"
}

ask() {
  # ask "Prompt: " [default]
  local prompt="${1:-}"
  local def="${2:-}"
  local ans=""
  if [[ -n "$def" ]]; then
    ans="$(_read_tty "${prompt} (${def}): ")"
    [[ -z "$ans" ]] && ans="$def"
  else
    ans="$(_read_tty "${prompt}: ")"
  fi
  printf "%s" "$ans"
}

confirm() {
  # confirm "Are you sure?"  -> returns 0 yes, 1 no
  local prompt="${1:-Are you sure}"
  local ans=""
  ans="$(_read_tty "${prompt} [y/N]: ")"
  case "${ans,,}" in
    y|yes) return 0 ;;
    *)     return 1 ;;
  esac
}

choose() {
  # choose "Prompt" "1) A" "2) B" ... ; prints selected number
  local prompt="$1"; shift
  local ans=""
  printf "%s\n" "$prompt" >&2
  local i=1
  for opt in "$@"; do
    printf "  %s\n" "$opt" >&2
    i=$((i+1))
  done
  ans="$(_read_tty "Select: ")"
  printf "%s" "$ans"
}

need_tty() {
  _ux_has_tty || die "No TTY available for interactive prompt (need ${UX_PROMPT_TTY})." 2
}

# -------------------------
# Optional: spinner wrapper
# -------------------------
_spinner() {
  # internal: _spinner <pid>
  local pid="$1"
  local frames='|/-\'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r%s" "${frames:i++%${#frames}:1}" >&2
    sleep 0.1
  done
  printf "\r \r" >&2
}

run() {
  # run <cmd...> : prints cmd, runs, returns exit code
  dbg "run: $*"
  if [[ "${UX_SPINNER}" == "1" ]] && _ux_is_tty; then
    "$@" &
    local pid=$!
    _spinner "$pid"
    wait "$pid"
    return $?
  fi
  "$@"
}

# -------------------------
# End
# -------------------------
