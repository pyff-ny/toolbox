#!/usr/bin/env bash
set -Eeuo pipefail
die(){ echo "[ERROR] $*" >&2; exit 1; }

TOOLBOX_DIR="${TOOLBOX_DIR:-$HOME/toolbox}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$TOOLBOX_DIR/scripts}"
WRAPPER_DIR="${WRAPPER_DIR:-$HOME/toolbox/bin}"
EDITOR_CMD="${EDITOR_CMD:-code}"

RULES_SH="$TOOLBOX_DIR/_lib/rules.sh"
[[ -f "$RULES_SH" ]] || die "rules not found: $RULES_SH"
# shellcheck source=/dev/null
source "$RULES_SH"

command -v fzf >/dev/null 2>&1 || { echo "[ERROR] fzf not found"; exit 1; }

# ---------- Input Helpers ----------
#为什么不用普通 read -r？因为你这里是 fzf + trap 场景，明确从 /dev/tty 读最稳。
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
# run_cmd - 稳定版本（兼容性最强）
# ===================================================================

run_cmd() {
  local rel="$1"
  local fullpath="$2"
  local filename="$3"
  shift 3
  local extra_args=("$@")
  
  # 调试输出（安全版本）

  if [[ "${DEBUG:-0}" == "1" ]]; then
    echo "[DEBUG] REL=$rel DIR=$fullpath FILE=$filename" >&2
    echo "[DEBUG] ARGS=${extra_args[*]}" >&2
  fi


  # 显示运行信息
  echo
  echo "[RUN] $rel  ->  $fullpath/$filename"
  
  if [[ ${#extra_args[@]} -gt 0 ]]; then
    echo "[ARGS] ${extra_args[*]}"
  fi
  
  echo "[INFO] Press Ctrl+C to stop and return to menu"
  echo
  
  # 在子 shell 中运行（隔离信号处理）
  (
    # 捕获 Ctrl+C
    trap 'echo; echo "[INFO] Script interrupted. Returning to menu..."; exit 130' INT
    
    # 根据文件类型执行
    case "$filename" in
      *.sh)
        bash "$fullpath/$filename" "${extra_args[@]}"
        ;;
      *.py)
        python3 "$fullpath/$filename" "${extra_args[@]}"
        ;;
      *)
        "$fullpath/$filename" "${extra_args[@]}"
        ;;
    esac
  )
  
  # 获取退出码
  local exit_code=$?
  
  # 显示结果
  echo
  case $exit_code in
    0)
      echo "[OK] Script completed successfully"
      ;;
    130)
      echo "[INFO] Script stopped by user"
      ;;
    *)
      echo "[WARN] Script exited with code: $exit_code"
      ;;
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

ensure_wrapper_dir() {
  mkdir -p "$WRAPPER_DIR"
}

lyrics_auto_no_vad() {
  local rel="media/lyrics_auto_no_vad.sh"
  local dir="$SCRIPTS_DIR/media"
  local file="lyrics_auto_no_vad.sh"
  [[ -f "$dir/$file" ]] || die "lyrics script not found: $dir/$file"

  local in lang mode interval
  in="$(read_tty "Audio file path: ")"
  [[ -n "$in" ]] || { echo "[WARN] cancelled"; return 0; }
  [[ -f "$in" ]] || die "audio file not found: $in"

  lang="$(read_tty "Lang (default: en): ")"; lang="${lang:-en}"
  mode="$(read_tty "Mode (auto|fixed|hybrid) (default: hybrid): ")"; mode="${mode:-hybrid}"
  interval="$(read_tty "Interval seconds (default: 12): ")"; interval="${interval:-12}"

  echo
  run_cmd "$rel" "$dir" "$file" "$in" "$lang" "$mode" "$interval"
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




create_wrapper() {
  local fullpath="$1"
  local filename="$2"
  local category="${3:-}"

  ensure_wrapper_dir

  # 目标脚本（当前存在性校验）
  local target="$fullpath/$filename"
  [[ -f "$target" ]] || die "Script not found: $target"

  # 计算相对 $SCRIPTS_DIR 的路径，避免目录调整后分叉
  # 例如 fullpath=/Users/jiali/toolbox/scripts/novel
  # rel_dir=novel
  local rel_dir
  if [[ "$fullpath" == "$SCRIPTS_DIR"* ]]; then
    rel_dir="${fullpath#"$SCRIPTS_DIR"/}"
  else
    # 如果 fullpath 不在 scripts 下面，就仍旧走绝对路径（但提示风险）
    rel_dir=""
  fi

  local name
  name="$(cmd_to_name "$filename" "$category")"
  local wrapper="$WRAPPER_DIR/$name"

  if [[ -e "$wrapper" ]]; then
    echo "[INFO] Wrapper exists: $wrapper"
    echo "Overwrite? (y/N)"
    read -r ans
    [[ "${ans:-N}" =~ ^[Yy]$ ]] || return 0
  fi

  # wrapper 内容：优先用 scripts 相对路径；否则回退绝对路径
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
  local name
  name="$(cmd_to_name "$filename" "$category")"
  local wrapper="$WRAPPER_DIR/$name"

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
  local name
  name="$(cmd_to_name "$filename" "$category")"
  local wrapper="$WRAPPER_DIR/$name"

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


# ---------- FZF Menus ----------
choose_one() {
  local prompt="$1"
  fzf --prompt="$prompt" --height=12 --border --no-info 2>/dev/null
}


#menu_actions 变成“读能力表”的纯展示层
menu_actions() {
  local rel="${1:-}"

  {
    # Run now / dry-run
    if ! cap_has "$rel" "NEEDS_ARGS"; then
      echo "Run now"
      if cap_has "$rel" "DRYRUN"; then
        echo "Run with --dry-run"
      fi
    fi

    # Run with prompts
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

  # 主循环忽略 INT，避免 Ctrl+C 直接退出整个 toolbox
  trap '' INT

  while true; do
    local LIST SEL REL DIR FILE ACT

    LIST="$(list_cmds_all "$SCRIPTS_DIR")"
    [[ -n "$LIST" ]] || die "No commands under: $SCRIPTS_DIR"

    # 让 fzf 能接收 Ctrl+C：临时恢复默认 INT
    trap - INT
    SEL="$(printf "Back\n%s" "$LIST" | choose_one "Cmd > " || true)"
    trap '' INT

    [[ -n "${SEL:-}" ]] || continue
    [[ "$SEL" == "Back" ]] && exit 0

    # SEL 是相对路径：e.g. net/wifi_watch.sh
    REL="$SEL"
    DIR="$(dirname "$REL")"
    FILE="$(basename "$REL")"

    # 统一成真实目录路径
    if [[ "$DIR" == "." ]]; then
      DIR="$SCRIPTS_DIR"
    else
      DIR="$SCRIPTS_DIR/$DIR"
    fi

    # Action Menu（对一个命令反复操作）
    while true; do
      trap - INT
      
      #对比调试输出，确定路径是否一致
      #echo "[DBG] REL=$REL  DIR=$DIR  FILE=$FILE" >/dev/tty
      ACT="$(menu_actions "$REL" "$FILE" || true)"
      trap '' INT

      [[ -n "${ACT:-}" ]] || break

      case "$ACT" in
        "Run now")
          run_cmd "$REL" "$DIR" "$FILE"
          ;;
        "Run with --dry-run")
          run_cmd "$REL" "$DIR" "$FILE" "--dry-run"
          ;;
        "Run with prompts")
          # 扁平化后：不再传 ROOT/SUB
          run_with_prompts "$REL"
          ;;
        "Create wrapper")
          # 这里建议把 category 传 REL 的 dirname，避免重名
          # 例如 net/wifi_watch.sh -> category="net"
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
        "Lyrics:Transcribe(whisper-cpp)")
            IN="$(read_tty "Audio file path: ")"
            LANG="$(read_tty "Lang (default: en): ")"; [[ -n "$LANG" ]] || LANG="en"
            MODE="$(read_tty "Mode (auto|fixed|hybrid) (default: hybrid): ")"; [[ -n "$MODE" ]] || MODE="hybrid"
            INTERVAL="$(read_tty "Interval seconds (default: 12): ")"; [[ -n "$INTERVAL" ]] || INTERVAL="12"

            lyrics_auto_no_vad "$IN" "$LANG" "$MODE" "$INTERVAL"
            #run_cmd "/Users/jiali/toolbox/scripts/media" "lyrics_auto_no_vad.sh" "$IN" "$LANG" "$MODE" "$INTERVAL"
          ;;

        "Lyrics:Import to Obsidian")
           WORKDIR="$(read_tty "Work dir (contains meta.txt + txt): ")"
           lyrics_import_obsidian "$WORKDIR"
           #run_cmd "/Users/jiali/toolbox/scripts/media" "lyrics_import_obsidian.sh" "$WORKDIR"
          ;;

        "Back")
          break
          ;;
      esac
    done
  done
}


main "$@"
