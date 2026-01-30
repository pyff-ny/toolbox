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
set -Eeuo pipefail

# -------------------------
# Internal helpers
# -------------------------
_ux_trim() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "$s"
}

ux_normalize_path() {
  local p="${1-}"
  p="$(_ux_trim "$p")"

  # strip surrounding quotes
  p="${p%\"}"; p="${p#\"}"
  p="${p%\'}"; p="${p#\'}"

  # common Terminal drag escapes: "\ " -> " "
  p="${p//\\ / }"

  # strip file://
  p="${p#file://}"

  printf "%s" "$p"
}

_ux_print_tty() { printf "%s" "${1-}" >/dev/tty; }
_ux_println_tty() { printf "%s\n" "${1-}" >/dev/tty; }

# read a line from /dev/tty into stdout
_ux_readline_tty() {
  local out=""
  IFS= read -r out </dev/tty || return 1
  printf "%s" "$out"
}

# Return code constants
UX_CANCEL=130

# -------------------------
# Public API
# -------------------------

# ux_read_tty <prompt> [default] [allow_empty(0|1)]
ux_read_tty() {
  local prompt="${1-}"
  local def="${2-}"
  local allow_empty="${3-0}"

  [[ -n "$prompt" ]] || return 2

  _ux_print_tty "$prompt"
  local raw=""
  if ! raw="$(_ux_readline_tty)"; then
    return $UX_CANCEL
  fi

  raw="$(_ux_trim "$raw")"
  if [[ -z "$raw" ]]; then
    if [[ -n "$def" ]]; then
      printf "%s" "$def"
      return 0
    fi
    if [[ "$allow_empty" == "1" ]]; then
      printf "%s" ""
      return 0
    fi
    return $UX_CANCEL
  fi

  printf "%s" "$raw"
  return 0
}

# ux_confirm <prompt> [word=YES]
ux_confirm() {
  local prompt="${1-}"
  local word="${2-YES}"
  [[ -n "$prompt" ]] || return 2

  _ux_print_tty "$prompt"
  local raw=""
  if ! raw="$(_ux_readline_tty)"; then
    return $UX_CANCEL
  fi

  raw="$(_ux_trim "$raw")"
  [[ -n "$raw" ]] || return $UX_CANCEL

  if [[ "$raw" == "$word" ]]; then
    return 0
  fi
  return 1
}

# ux_open_dir <dir>
ux_open_dir() {
  local d="${1-}"
  [[ -n "$d" ]] || return 2
  [[ -d "$d" ]] || return 2
  command -v open >/dev/null 2>&1 || return 0
  open "$d" >/dev/null 2>&1 || true
  return 0
}

# ux_pick_dir <start_dir> [prompt]
ux_pick_dir() {
  local start_dir="${1-}"
  local prompt="${2-Drag folder here: }"

  [[ -n "$start_dir" ]] || return 2
  [[ -d "$start_dir" ]] || return 2

  ux_open_dir "$start_dir" || true
  local raw=""
  raw="$(ux_read_tty "$prompt" "" 0)" || return $?
  raw="$(ux_normalize_path "$raw")"
  [[ -n "$raw" ]] || return $UX_CANCEL
  [[ -d "$raw" ]] || return 2
  printf "%s" "$raw"
  return 0
}

# ux_open_after <path> [label]
# - open folder/file in Finder after success
# - controlled by AUTO_OPEN=1/0 (default: 1)
ux_open_after() {
  local p="${1-}"
  local label="${2-Open}"

  local auto="${AUTO_OPEN:-1}"
  [[ "$auto" == "1" ]] || return 0

  [[ -n "$p" ]] || return 0
  command -v open >/dev/null 2>&1 || return 0

  # open directory if file path provided
  if [[ -f "$p" ]]; then
    open -R "$p" >/dev/null 2>&1 & disown || true
    return 0
  fi

  if [[ -d "$p" ]]; then
    open "$p" >/dev/null 2>&1 & disown || true
    return 0
  fi

  return 0
}

# ux_pick_file_drag <start_dir> [prompt] [must_exist(1|0)]
ux_pick_file_drag() {
  local start_dir="${1-}"
  local prompt="${2-Audio file path (drag here): }"
  local must_exist="${3-1}"

  [[ -n "$start_dir" ]] || return 2
  [[ -d "$start_dir" ]] || return 2

  ux_open_dir "$start_dir" || true
  local raw=""
  raw="$(ux_read_tty "$prompt" "" 0)" || return $?
  raw="$(ux_normalize_path "$raw")"
  [[ -n "$raw" ]] || return $UX_CANCEL

  if [[ "$must_exist" == "1" ]]; then
    [[ -f "$raw" ]] || return 2
  fi

  printf "%s" "$raw"
  return 0
}

# ux_choose <prompt> <items...>
# - uses fzf if available; fallback to numbered menu.
ux_choose() {
  local prompt="${1-}"; shift || true
  [[ -n "$prompt" ]] || return 2

  local items=("$@")
  [[ ${#items[@]} -gt 0 ]] || return 2

  if command -v fzf >/dev/null 2>&1; then
    _ux_println_tty "$prompt"
    local picked=""
    picked="$(printf "%s\n" "${items[@]}" | fzf --prompt="> " </dev/tty)" || return $UX_CANCEL
    picked="$(_ux_trim "$picked")"
    [[ -n "$picked" ]] || return $UX_CANCEL
    printf "%s" "$picked"
    return 0
  fi

  # fallback: numbered
  _ux_println_tty "$prompt"
  local i=0
  for i in "${!items[@]}"; do
    _ux_println_tty "  $((i+1))) ${items[$i]}"
  done
  _ux_println_tty "  q) Cancel"

  local ans=""
  ans="$(ux_read_tty "Select: " "" 0)" || return $?
  ans="$(_ux_trim "$ans")"
  [[ "$ans" != "q" && "$ans" != "Q" ]] || return $UX_CANCEL

  [[ "$ans" =~ ^[0-9]+$ ]] || return 1
  local idx=$((ans-1))
  (( idx >= 0 && idx < ${#items[@]} )) || return 1
  printf "%s" "${items[$idx]}"
  return 0
}

# ux_tip <title> <lines...>
#ux_tip的标准签名（最好固定下来）
#ux_tip "<Tips>" \
#  "<tip line 1>" \
#  "<tip line 2>" \
#  "<tip line 3>"

ux_tip() {
  local title="${1-Tips}"; shift || true
  _ux_println_tty "💡 ${title}:"
  local line=""
  for line in "$@"; do
    _ux_println_tty "  - $line"
  done
  return 0
}

normalize_mode() {
  local m="${1-}"
  m="$(_ux_trim "$m")"
  m="${m,,}"
  m="${m#:}"
  printf "%s" "$m"
}

normalize_interval() {
  local x="${1-}"
  x="$(_ux_trim "$x")"
  x="${x#:}"
  [[ "$x" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  printf "%s" "$x"
}

