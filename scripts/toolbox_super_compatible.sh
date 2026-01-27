#!/usr/bin/env bash
set -Eeuo pipefail
TOOLBOX_VERSION="2026-01-26.2"
echo "[INFO] toolbox version: $TOOLBOX_VERSION"


TOOLBOX_DIR="${TOOLBOX_DIR:-$HOME/toolbox}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$TOOLBOX_DIR/scripts}"
WRAPPER_DIR="${WRAPPER_DIR:-$HOME/toolbox/bin}"
EDITOR_CMD="${EDITOR_CMD:-code}"

command -v fzf >/dev/null 2>&1 || { echo "[ERROR] fzf not found"; exit 1; }

die(){ echo "[ERROR] $*" >&2; exit 1; }

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

# ---------- Exec ----------
run_cmd() {
  local fullpath="$1"
  local filename="$2"
  shift 2
  local extra_args=("$@")

  echo
  printf '[RUN] %s/%s %s\n' "$fullpath" "$filename" "${extra_args[*]:-}"
  printf '[RUN] %s/%s argv=%q\n' "$fullpath" "$filename" "$*"
  echo "[INFO] Press Ctrl+C to stop and return to menu"
  echo

  (
    trap 'echo; echo "[INFO] Script interrupted. Returning to menu..."; exit 130' INT

    case "$filename" in
      *.sh) bash "$fullpath/$filename" "${extra_args[@]}" ;;
      *.py) python3 "$fullpath/$filename" "${extra_args[@]}" ;;
      *)    "$fullpath/$filename" "${extra_args[@]}" ;;
    esac
  )

  local exit_code=$?
  echo
  if [[ $exit_code -eq 130 ]]; then
    echo "[INFO] Script stopped by user"
  elif [[ $exit_code -ne 0 ]]; then
    echo "[WARN] Script exited with code: $exit_code"
  else
    echo "[OK] Script completed successfully"
  fi
  echo
  echo "Press Enter to continue..."
  read -r
}

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


run_with_prompts() {
  local dir="$1"
  local cmd="$2"
  local root="${3:-}"
  local sub="${4:-}"

  case "$cmd" in
    novel_crawler*|novel_novel_crawler*)
      # 对 Novel Crawler：永远走原生交互（直通）
      #不输出Run with prompts
      ;;
    check_disk_health*)
    # 对 check_disk_health：永远走直通
      ;;
    *)
      echo " Run with prompts"
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

#增加参数（cmd name），按条件输出

menu_actions() {
  local cmd="${1:-}"
  {
    echo "Run now"
    echo "Run with --dry-run"

    case "$cmd" in
      novel_crawler*|novel_novel_crawler*)
        : ;;   # hide
      *)
        echo "Run with prompts"
        ;;
    esac

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
      ACT="$(menu_actions "$FILE" || true)"
      trap '' INT

      [[ -n "${ACT:-}" ]] || break

      case "$ACT" in
        "Run now")
          run_cmd "$DIR" "$FILE"
          ;;
        "Run with --dry-run")
          run_cmd "$DIR" "$FILE" "--dry-run"
          ;;
        "Run with prompts")
          # 扁平化后：不再传 ROOT/SUB
          run_with_prompts "$DIR" "$FILE" "" ""
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
        "Back")
          break
          ;;
      esac
    done
  done
}


main "$@"
