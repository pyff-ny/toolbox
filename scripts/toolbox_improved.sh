#!/usr/bin/env bash
set -Eeuo pipefail

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

  echo
  echo "[RUN] $fullpath/$filename"
  echo

  local target="$fullpath/$filename"
  case "$filename" in
    *.sh)
      bash "$target" </dev/tty >/dev/tty 2>&1
      ;;
    *.py)
      python3 "$target" </dev/tty >/dev/tty 2>&1
      ;;
    *)
      "$target" </dev/tty >/dev/tty 2>&1
      ;;
  esac
}


cmd_to_name() {
  local f="$1"
  local category="${2:-}"  # 添加分类参数避免冲突
  f="${f##*/}"
  local base="${f%.sh}"
  base="${base%.py}"
  
  # 如果提供了分类，添加前缀
  if [[ -n "$category" ]]; then
    echo "${category}_${base}"
  else
    echo "$base"
  fi
}

ensure_wrapper_dir() {
  mkdir -p "$WRAPPER_DIR"
}

create_wrapper() {
  local fullpath="$1"
  local filename="$2"
  local category="${3:-}"
  local target="$fullpath/$filename"
  [[ -f "$target" ]] || die "Script not found: $target"

  ensure_wrapper_dir

  local name
  name="$(cmd_to_name "$filename" "$category")"
  local wrapper="$WRAPPER_DIR/$name"

  if [[ -e "$wrapper" ]]; then
    echo "[INFO] Wrapper exists: $wrapper"
    echo "Overwrite? (y/N)"
    read -r ans
    [[ "${ans:-N}" =~ ^[Yy]$ ]] || return 0
  fi

  cat > "$wrapper" <<EOF
#!/usr/bin/env bash
# Auto-generated wrapper for: $fullpath/$filename
exec "$target" "\$@"
EOF
  chmod +x "$wrapper"

  echo "[OK] Wrapper created: $wrapper"
  echo "Usage: $name [args...]"
  
  # 提示添加到 PATH
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
  fzf --prompt="$prompt" --height=12 --border --no-info
}

menu_actions() {
  cat <<'EOF' | choose_one "Action > "
Run now
Create wrapper
Preview wrapper
Open in editor
Delete wrapper
Back
EOF
}

# ---------- Main Loop ----------
main() {
  [[ -d "$SCRIPTS_DIR" ]] || die "SCRIPTS_DIR not found: $SCRIPTS_DIR"

  while true; do
    # Level 1: Root category
    mapfile -t ROOT_ITEMS < <(list_dirs "$SCRIPTS_DIR")
    [[ "${#ROOT_ITEMS[@]}" -gt 0 ]] || die "No categories under: $SCRIPTS_DIR"

    ROOT_SEL="$(printf "Back\n%s\n" "${ROOT_ITEMS[@]}" | choose_one "Root > ")"
    [[ -n "${ROOT_SEL:-}" ]] || exit 0
    [[ "$ROOT_SEL" == "Back" ]] && exit 0

    local CAT_DIR="$SCRIPTS_DIR/$ROOT_SEL"

    while true; do
      # Level 2: Sub-dir or direct commands
      mapfile -t SUB_DIRS < <(list_dirs "$CAT_DIR")
      mapfile -t CAT_CMDS < <(list_cmds_in_dir "$CAT_DIR")

      # 构建选择列表
      local -a ITEMS=("Back")
      for d in "${SUB_DIRS[@]}"; do ITEMS+=("[DIR] $d"); done
      for c in "${CAT_CMDS[@]}"; do ITEMS+=("[CMD] $c"); done

      CHOICE="$(printf "%s\n" "${ITEMS[@]}" | choose_one "$ROOT_SEL > ")"
      [[ -n "${CHOICE:-}" ]] || break
      [[ "$CHOICE" == "Back" ]] && break

      # 选中子目录
      if [[ "$CHOICE" == "[DIR]"* ]]; then
        SUB_SEL="${CHOICE#"[DIR] "}"
        SUB_PATH="$CAT_DIR/$SUB_SEL"

        # Level 3: commands in sub
        while true; do
          mapfile -t CMDS < <(list_cmds_in_dir "$SUB_PATH")
          [[ "${#CMDS[@]}" -gt 0 ]] || { echo "[INFO] No commands in $SUB_PATH"; break; }

          CMD_SEL="$(printf "Back\n%s\n" "${CMDS[@]}" | choose_one "$ROOT_SEL/$SUB_SEL > ")"
          [[ -n "${CMD_SEL:-}" ]] || break
          [[ "$CMD_SEL" == "Back" ]] && break

          # Action Menu
          while true; do
            ACT="$(menu_actions)"
            [[ -n "${ACT:-}" ]] || break

            case "$ACT" in
              "Run now")         run_cmd "$SUB_PATH" "$CMD_SEL" ;;
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
        CMD_SEL="${CHOICE#"[CMD] "}"
        while true; do
          ACT="$(menu_actions)"
          [[ -n "${ACT:-}" ]] || break

          case "$ACT" in
            "Run now")         run_cmd "$CAT_DIR" "$CMD_SEL" ;;
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
