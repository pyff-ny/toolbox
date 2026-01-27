#!/usr/bin/env bash
set -Eeuo pipefail
TOOLBOX_VERSION="2026-01-26.1"
echo "[INFO] toolbox version: $TOOLBOX_VERSION"


TOOLBOX_DIR="${TOOLBOX_DIR:-$HOME/toolbox}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$TOOLBOX_DIR/scripts}"
WRAPPER_DIR="${WRAPPER_DIR:-$HOME/toolbox/bin}"
EDITOR_CMD="${EDITOR_CMD:-code}"

command -v fzf >/dev/null 2>&1 || { echo "[ERROR] fzf not found"; exit 1; }

die(){ echo "[ERROR] $*" >&2; exit 1; }

# ---------- Scan Helpers ----------
list_dirs() {
  local base="$1"
  [[ -d "$base" ]] || return 0
  find "$base" -mindepth 1 -maxdepth 1 -type d \
    ! -name "_lib" ! -name "conf" ! -name ".git" \
    -exec basename {} \; | sort
}

list_cmds_in_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  find "$dir" -maxdepth 1 -type f \
    ! -name "README*" ! -name ".DS_Store" \
    ! -name "*_final_v*.py" \
    -exec basename {} \; | sort
}

# ---------- Exec ----------
run_cmd() {
  local fullpath="$1"
  local filename="$2"
  shift 2
  local extra_args=("$@")

  local cmd_path="$fullpath/$filename"

  echo
  printf '[RUN] %s' "$cmd_path"
  if (( ${#extra_args[@]} > 0 )); then
    printf ' %q' "${extra_args[@]}"
  fi
  printf '\n'
  echo "[INFO] Press Ctrl+C to stop and return to menu"
  echo

  (
    # 子 shell 捕获 Ctrl+C：中断整个进程组，然后以 130 退出
    trap 'echo; echo "[INFO] Script interrupted. Returning to menu..."; kill -INT 0; exit 130' INT

    case "$filename" in
      *.sh) bash    "$cmd_path" "${extra_args[@]}" ;;
      *.py) python3 "$cmd_path" "${extra_args[@]}" ;;
      *)    "$cmd_path"         "${extra_args[@]}" ;;
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
  
  # 主循环忽略 INT 信号，防止 Ctrl+C 退出整个程序
  trap '' INT

  while true; do
    # Level 1: Root category
    local ROOT_LIST
    ROOT_LIST=$(list_dirs "$SCRIPTS_DIR")
    [[ -n "$ROOT_LIST" ]] || die "No categories under: $SCRIPTS_DIR"

    local ROOT_SEL
    
    # fzf 需要能响应 Ctrl+C，所以临时恢复默认行为
    trap - INT
    ROOT_SEL="$(printf "Back\n%s" "$ROOT_LIST" | choose_one "Root > " || true)"
    trap '' INT
    
    [[ -n "${ROOT_SEL:-}" ]] || continue
    [[ "$ROOT_SEL" == "Back" ]] && exit 0

    local CAT_DIR="$SCRIPTS_DIR/$ROOT_SEL"

    while true; do
      # Level 2: Sub-dir or direct commands
      local SUB_LIST CMD_LIST ITEMS
      SUB_LIST=$(list_dirs "$CAT_DIR")
      CMD_LIST=$(list_cmds_in_dir "$CAT_DIR")

      # 构建选择列表
      ITEMS="Back"$'\n'
      if [[ -n "$SUB_LIST" ]]; then
        while IFS= read -r d; do
          ITEMS+="[DIR] $d"$'\n'
        done <<< "$SUB_LIST"
      fi
      if [[ -n "$CMD_LIST" ]]; then
        while IFS= read -r c; do
          ITEMS+="[CMD] $c"$'\n'
        done <<< "$CMD_LIST"
      fi

      local CHOICE
      trap - INT
      CHOICE="$(printf "%s" "$ITEMS" | choose_one "$ROOT_SEL > " || true)"
      trap '' INT
      
      [[ -n "${CHOICE:-}" ]] || break
      [[ "$CHOICE" == "Back" ]] && break

      # 选中子目录
      if [[ "$CHOICE" == "[DIR]"* ]]; then
        local SUB_SEL="${CHOICE#"[DIR] "}"
        local SUB_PATH="$CAT_DIR/$SUB_SEL"

        # Level 3: commands in sub
        while true; do
          local CMDS
          CMDS=$(list_cmds_in_dir "$SUB_PATH")
          [[ -n "$CMDS" ]] || { echo "[INFO] No commands in $SUB_PATH"; sleep 2; break; }

          local CMD_SEL
          trap - INT
          CMD_SEL="$(printf "Back\n%s" "$CMDS" | choose_one "$ROOT_SEL/$SUB_SEL > " || true)"
          trap '' INT
          
          [[ -n "${CMD_SEL:-}" ]] || break
          [[ "$CMD_SEL" == "Back" ]] && break

          # Action Menu
          while true; do
            local ACT
            trap - INT
            ACT="$(menu_actions "$CMD_SEL" || true)"
            trap '' INT
            
            [[ -n "${ACT:-}" ]] || break

            case "$ACT" in
              "Run now")         run_cmd "$SUB_PATH" "$CMD_SEL" ;;
              "Run with --dry-run") run_cmd "$SUB_PATH" "$CMD_SEL" "--dry-run" ;;
              "Run with prompts") run_with_prompts "$SUB_PATH" "$CMD_SEL" "$ROOT_SEL" "$SUB_SEL";;
              "Create wrapper")  create_wrapper "$SUB_PATH" "$CMD_SEL" "${ROOT_SEL}_${SUB_SEL}" ;;
              "Preview wrapper") preview_wrapper "$CMD_SEL" "${ROOT_SEL}_${SUB_SEL}" ;;
              "Open in editor")  open_in_editor "$SUB_PATH" "$CMD_SEL" ;;
              "Delete wrapper")  delete_wrapper "$CMD_SEL" "${ROOT_SEL}_${SUB_SEL}" ;;
              "Back")            break ;;
            esac
          done
        done

      # 选中当前分类目录里的命令（两级结构）
      else
        local CMD_SEL="${CHOICE#"[CMD] "}"
        while true; do
          local ACT
          trap - INT
          ACT="$(menu_actions "$CMD_SEL" || true)"
          trap '' INT
          
          [[ -n "${ACT:-}" ]] || break

          case "$ACT" in
            "Run now")         run_cmd "$CAT_DIR" "$CMD_SEL" ;;
            "Run with --dry-run") run_cmd "$CAT_DIR" "$CMD_SEL" "--dry-run" ;;
            "Run with prompts") run_with_prompts "$CAT_DIR" "$CMD_SEL" "$ROOT_SEL" "" ;;
            "Create wrapper")  create_wrapper "$CAT_DIR" "$CMD_SEL" "$ROOT_SEL" ;;
            "Preview wrapper") preview_wrapper "$CMD_SEL" "$ROOT_SEL" ;;
            "Open in editor")  open_in_editor "$CAT_DIR" "$CMD_SEL" ;;
            "Delete wrapper")  delete_wrapper "$CMD_SEL" "$ROOT_SEL" ;;
            "Back")            break ;;
          esac
        done
      fi
    done
  done
}

main "$@"
