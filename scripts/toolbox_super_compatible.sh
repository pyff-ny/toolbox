#!/usr/bin/env bash
set -Eeuo pipefail

die(){ echo "[ERROR] $*" >&2; exit 1; }
# --- Load libs ---
TOOLBOX_DIR="${TOOLBOX_DIR:-$HOME/toolbox}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$TOOLBOX_DIR/scripts}"
WRAPPER_DIR="${WRAPPER_DIR:-$HOME/toolbox/bin}"
LIB_DIR="$TOOLBOX_DIR/scripts/_lib"
# shellcheck source=/dev/null
source "$TOOLBOX_DIR/_lib/rules.sh" #die,etc
# shellcheck source=/dev/null
source "$LIB_DIR/log.sh" # log_ok,log_info,log_warn
source "$LIB_DIR/std.sh" # std_* uses logging
source "$LIB_DIR/ux.sh"  # ux_show_subscript, ux_confirm_delete

SCRIPT_TITLE="Lyrics Auto (No VAD)"
RUN_TS="$(std_now_ts)"

# defaults
std_default DRY_RUN "false"

EDITOR_CMD="${EDITOR_CMD:-code}"


echo "VERSION_STR="toolbox_super_compatible.sh_2026-01-30.1""
command -v fzf >/dev/null 2>&1 || die "fzf not found"

# ============================================================
# Signals: policy
# - Menu layer:
#   - Ctrl+C: do NOT exit; show hint ("use option Back/Exit")
#   - Ctrl+Z: disabled (no suspend jobs)
# - Task layer (run_cmd):
#   - Ctrl+C: stop current task, return to menu
#   - Ctrl+Z: disabled
# ============================================================

on_tstp() {
  # 强制打到真实终端，避免 stdout 被管道/fzf 吃掉
  printf "\n[INFO] Ctrl+Z disabled in toolbox. Use Ctrl+C to stop a running task.\n" >/dev/tty
  # 让终端行编辑恢复一下（清行+回车）
  printf "\r\033[2K" >/dev/tty
}


on_int_menu() {
  echo
  echo "[INFO] Use 'Back' / menu option to exit. (Ctrl+C is reserved for stopping a running task.)"
}

enable_menu_signal_policy() {
  trap 'on_tstp' TSTP
  trap 'on_int_menu' INT
}

# 进入 fzf 选择时：让 Ctrl+C 不退出主程序，但允许 fzf 自己处理返回（Esc/Ctrl+C）
# 这里的关键是：我们不把 INT “恢复默认导致退出脚本”，而是让 fzf 结束后我们继续循环。
enable_fzf_signal_policy() {
  trap 'on_tstp' TSTP
  # Ctrl+C 在 fzf 场景下，fzf 会退出并返回非 0；我们用 || true 吞掉即可
  trap '' INT
}

# ---------- Input Helpers ----------
# 为什么不用普通 read -r？因为你这里是 fzf + trap 场景，明确从 /dev/tty 读最稳。
read_tty() {
  local prompt="$1"
  local out=""
  printf "%s" "$prompt" >/dev/tty
  IFS= read -r out </dev/tty || true
  printf "%s" "$out"
}

# ---------- Scan Helpers ----------
list_cmds_all() {
  local base="$1"
  [[ -d "$base" ]] || return 0

  find "$base" -type f \
    ! -path "*/_lib/*" \
    ! -path "*/conf/*" \
    ! -path "*/.git/*" \
    ! -name "README*" \
    ! -name ".DS_Store" \
    ! -name "*_final_v*.py" \
    \( -name "*.sh" -o -name "*.py" -o -perm -111 \) \
    -print | sed "s|^$base/||" | sort
}

list_cmds_in_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0

  find "$dir" -maxdepth 1 -type f \
    ! -name "README*" \
    ! -name ".DS_Store" \
    ! -name "*_final_v*.py" \
    \( -name "*.sh" -o -name "*.py" -o -perm -111 \) \
    -print | sed "s|^$dir/||" | sort
}

# ===================================================================
# run_cmd - stable version
# - Runs exactly once
# - Task-scope signal handling (INT=130, TSTP disabled)
# ===================================================================
run_cmd() {
  local rel="$1"
  local fullpath="$2"
  local filename="$3"
  shift 3
  local extra_args=("$@")
 
  echo
  echo "[RUN] $rel  ->  $fullpath/$filename"
  (( ${#extra_args[@]} )) && echo "[ARGS] ${extra_args[*]}"
  echo "[INFO] Press Ctrl+C to stop and return to menu"
  echo

  # 关键：set -e 下，130 会把主程序干掉；所以这里必须自己接管返回码
  local exit_code=0

  # 父层：运行子任务期间忽略 INT，避免父层也被 SIGINT 杀掉
  local old_int old_tstp
  old_int="$(trap -p INT || true)"
  old_tstp="$(trap -p TSTP || true)"
  trap '' INT
  trap 'on_tstp' TSTP

  # 子层：运行子脚本时，Ctrl+C 能中断子脚本并返回到这里

  (
    trap 'echo; echo "[INFO] Script interrupted. Returning to menu..."; exit 130' INT
    trap 'on_tstp' TSTP

    case "$filename" in
      *.sh) bash "$fullpath/$filename" "${extra_args[@]}" ;;
      *.py) python3 "$fullpath/$filename" "${extra_args[@]}" ;;
      *)    "$fullpath/$filename" "${extra_args[@]}" ;;
    esac
  )
  exit_code=$?


  # 恢复父层 trap
  eval "$old_int"
  eval "$old_tstp"

  echo
  case "$exit_code" in
    0)   echo "[OK] Script completed successfully" ;;
    130) echo "[INFO] Script stopped by user" ;;
    *)   echo "[WARN] Script exited with code: $exit_code" ;;
  esac
  echo
  read_tty "Press Enter to continue..."
}


# ---------- Wrapper Management ----------
cmd_to_name() {
  local f="$1"
  local category="${2:-}"
  f="${f##*/}"
  local base="${f%.sh}"
  base="${base%.py}"

  if [[ -n "$category" ]]; then
    echo "${category}_${base}"
  else
    echo "$base"
  fi
}

ensure_wrapper_dir() { mkdir -p "$WRAPPER_DIR"; }

create_wrapper() {
  local fullpath="$1"
  local filename="$2"
  local category="${3:-}"

  ensure_wrapper_dir

  local target="$fullpath/$filename"
  [[ -f "$target" ]] || die "Script not found: $target"

  local rel_dir=""
  if [[ "$fullpath" == "$SCRIPTS_DIR"* ]]; then
    rel_dir="${fullpath#"$SCRIPTS_DIR"/}"
  fi

  local name wrapper
  name="$(cmd_to_name "$filename" "$category")"
  wrapper="$WRAPPER_DIR/$name"

  if [[ -e "$wrapper" ]]; then
    echo "[INFO] Wrapper exists: $wrapper"
    echo "Overwrite? (y/N)"
    read -r ans
    [[ "${ans:-N}" =~ ^[Yy]$ ]] || return 0
  fi

  if [[ -n "$rel_dir" ]]; then
    cat > "$wrapper" <<EOF
#!/usr/bin/env bash
# Auto-generated launcher for: \$HOME/toolbox/scripts/$rel_dir/$filename
SCRIPTS_DIR="\${SCRIPTS_DIR:-\$HOME/toolbox/scripts}"
exec "\$SCRIPTS_DIR/$rel_dir/$filename" "\$@"
EOF
  else
    cat > "$wrapper" <<EOF
#!/usr/bin/env bash
# Auto-generated wrapper for: $target
exec "$target" "\$@"
EOF
    echo "[WARN] $fullpath is outside \$SCRIPTS_DIR; wrapper uses absolute path."
  fi

  chmod +x "$wrapper"
  echo "[OK] Wrapper created: $wrapper"
  echo "Usage: $name [args...]"

  if [[ ":$PATH:" != *":$WRAPPER_DIR:"* ]]; then
    echo "[TIP] Add to PATH: export PATH=\"\$PATH:$WRAPPER_DIR\""
  fi
}

preview_wrapper() {
  local filename="$1"
  local category="${2:-}"
  local name wrapper
  name="$(cmd_to_name "$filename" "$category")"
  wrapper="$WRAPPER_DIR/$name"

  if [[ ! -f "$wrapper" ]]; then
    echo "[INFO] No wrapper found: $wrapper"
    return 0
  fi

  echo "=== $wrapper ==="
  cat "$wrapper"
  echo "=================="
}

delete_wrapper() {
  local filename="$1"
  local category="${2:-}"
  local name wrapper
  name="$(cmd_to_name "$filename" "$category")"
  wrapper="$WRAPPER_DIR/$name"

  if [[ ! -e "$wrapper" ]]; then
    echo "[INFO] No wrapper found: $wrapper"
    return 0
  fi

  echo "Delete wrapper $wrapper ? (y/N)"
  read -r ans
  [[ "${ans:-N}" =~ ^[Yy]$ ]] || return 0

  rm -f "$wrapper"
  echo "[OK] Deleted: $wrapper"
}

open_in_editor() {
  local fullpath="$1"
  local filename="$2"
  local target="$fullpath/$filename"

  if command -v "$EDITOR_CMD" >/dev/null 2>&1; then
    "$EDITOR_CMD" "$target"
  else
    echo "[INFO] Editor not found: $EDITOR_CMD"
    echo "Tip: set EDITOR_CMD=vim or EDITOR_CMD=nano"
  fi
}
# ---------- Prompt-mode handlers ----------
lyrics_auto_no_vad() {
  local rel="media/lyrics_auto_no_vad.sh"
  local dir="$SCRIPTS_DIR/media"
  local file="lyrics_auto_no_vad.sh"
  [[ -f "$dir/$file" ]] || die "lyrics script not found: $dir/$file"

  run_cmd "$rel" "$dir" "$file"
}

lyrics_import_obsidian() {
  local rel="media/lyrics_import_obsidian.sh"
  local dir="$SCRIPTS_DIR/media"
  local file="lyrics_import_obsidian.sh"
  [[ -f "$dir/$file" ]] || die "lyrics import script not found: $dir/$file"

  local workdir
  workdir="$(read_tty "Workdir path (e.g. .../work_lyrics_xxx): ")"
  [[ -n "$workdir" ]] || { echo "[WARN] cancelled"; return 0; }
  [[ -d "$workdir" ]] || die "workdir not found: $workdir"

  echo
  run_cmd "$rel" "$dir" "$file" "$workdir"
}

run_with_prompts() {
  local rel="$1"
  case "$rel" in
    media/lyrics_auto_no_vad.sh) lyrics_auto_no_vad ;;
    media/lyrics_import_obsidian.sh) lyrics_import_obsidian ;;
    *)
      echo "[INFO] No prompt-mode handler for: $rel"
      ;;
  esac
}

# ---------- FZF Menus ----------
choose_one() {
  local prompt="$1"
  enable_fzf_signal_policy
  fzf --prompt="$prompt" --height=12 --border --no-info 2>/dev/null
}

menu_actions() {
  local rel="${1:-}"
  {
    if ! cap_has "$rel" "NEEDS_ARGS"; then
      echo "Run now"
      if cap_has "$rel" "DRYRUN" && ! cap_has "$rel" "HIDE_DRYRUN"; then
        echo "Run with --dry-run"
      fi
    fi

    if ! cap_has "$rel" "HIDE_PROMPTS"; then
      echo "Run with prompts"
    fi

    echo "Create wrapper"
    echo "Preview wrapper"
    echo "Open in editor"
    echo "Delete wrapper"
    echo "Back"
  } | choose_one "Action > "
}

# ---------- Main Loop ----------
main() {
  [[ -d "$SCRIPTS_DIR" ]] || die "SCRIPTS_DIR not found: $SCRIPTS_DIR"

  enable_menu_signal_policy

  while true; do
    local LIST SEL REL DIR FILE ACT

    LIST="$(list_cmds_all "$SCRIPTS_DIR")"
    [[ -n "$LIST" ]] || die "No commands under: $SCRIPTS_DIR"

    SEL="$(printf "Back\n%s" "$LIST" | choose_one "Cmd > " || true)"
    enable_menu_signal_policy

    [[ -n "${SEL:-}" ]] || continue
    [[ "$SEL" == "Back" ]] && exit 0

    REL="$SEL"
    DIR="$(dirname "$REL")"
    FILE="$(basename "$REL")"

    if [[ "$DIR" == "." ]]; then
      DIR="$SCRIPTS_DIR"
    else
      DIR="$SCRIPTS_DIR/$DIR"
    fi

    while true; do
      ACT="$(menu_actions "$REL" "$FILE" || true)"
      enable_menu_signal_policy

      [[ -n "${ACT:-}" ]] || break

      case "$ACT" in
        "Run now")
          run_cmd "$REL" "$DIR" "$FILE"
          ;;
        "Run with --dry-run")
          run_cmd "$REL" "$DIR" "$FILE" "--dry-run"
          ;;
        "Run with prompts")
          run_with_prompts "$REL"
          ;;
        "Create wrapper")
          create_wrapper "$DIR" "$FILE" "$(dirname "$REL")"
          ;;
        "Preview wrapper")
          preview_wrapper "$FILE" "$(dirname "$REL")"
          ;;
        "Open in editor")
          open_in_editor "$DIR" "$FILE"
          ;;
        "Delete wrapper")
          delete_wrapper "$FILE" "$(dirname "$REL")"
          ;;
        "Back")
          break
          ;;
      esac
    done
  done
}

main "$@"
