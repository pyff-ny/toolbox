#!/usr/bin/env bash
set -euo pipefail

TOOLBOX_DIR="${TOOLBOX_DIR:-$HOME/toolbox}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$TOOLBOX_DIR/scripts}"
BIN_DIR="${BIN_DIR:-$TOOLBOX_DIR/bin}"

command -v fzf >/dev/null 2>&1 || { echo "[ERROR] fzf not found"; exit 1; }

# 扫描 scripts 目录（只取目录，不包含 _lib/conf 等）
list_dirs() {
  local base="$1"
  find "$base" -mindepth 1 -maxdepth 1 -type d ...
    ! -name "." ! -name "_lib" ! -name "conf" ! -name ".git" \
    -exec basename {} \; | sort
}

# 扫描某个目录下的命令脚本（.sh/.py/无后缀都行）
list_cmds_in_dir() {
  local dir="$1"
  find "$dir" -maxdepth 1 -type f \
    ! -name "README*" ! -name ".DS_Store" \
    ! -name "*_final_v*.py" \
    -exec basename {} \; | sort
}

run_cmd() {
  local rel="$1"      # rel path under scripts/
  local cmd="$2"      # command file name
  local target="$SCRIPTS_DIR/$rel/$cmd"

  echo
  echo "[RUN] $rel/$cmd"
  echo

  case "$cmd" in
    *.sh) bash "$target" ;;
    *.py) python3 "$target" ;;
    *)    "$target" ;;
  esac
}

# ---------- Level 1: Root ----------
mapfile -t ROOT_ITEMS < <(list_dirs "$SCRIPTS_DIR")
ROOT_SEL="$(printf "%s\n" "${ROOT_ITEMS[@]}" | fzf --prompt="Root > " --height=12 --border)"

[[ -n "$ROOT_SEL" ]] || exit 0

# 如果选的是 scripts 根目录下“直接脚本区”，你也可以做成 Root 直跑
# 这里我们认为 Root_SEL 是 category 目录
CAT_DIR="$SCRIPTS_DIR/$ROOT_SEL"

# ---------- Level 2: Category ----------
SUB_DIRS=()
while IFS= read -r line; do
  SUB_DIRS+=("$line")
done < <(list_dirs "$CAT_DIR")

# 如果 category 下没有子目录 → 直接列命令
if [[ "${#SUB_DIRS[@]}" -eq 0 ]]; then
  CMDS=()
  while IFS= read -r line; do
    CMDS+=("$line")
  done < <(list_cmds_in_dir "$CAT_DIR")

  CMD_SEL="$(printf "%s\n" "${CMDS[@]}" | fzf --prompt="$ROOT_SEL > " --height=12 --border)"
  [[ -n "$CMD_SEL" ]] || exit 0
  run_cmd "$ROOT_SEL" "$CMD_SEL"
  exit 0
fi

SUB_SEL="$(printf "%s\n" "${SUB_DIRS[@]}" | fzf --prompt="$ROOT_SEL > " --height=12 --border)"
[[ -n "$SUB_SEL" ]] || exit 0

SUB_PATH="$CAT_DIR/$SUB_SEL"

# ---------- Level 3: Sub-category commands ----------
CMDS=()
while IFS= read -r line; do
  CMDS+=("$line")
done < <(list_cmds_in_dir "$SUB_PATH")

CMD_SEL="$(printf "%s\n" "${CMDS[@]}" | fzf --prompt="$ROOT_SEL/$SUB_SEL > " --height=12 --border)"
[[ -n "$CMD_SEL" ]] || exit 0

run_cmd "$ROOT_SEL/$SUB_SEL" "$CMD_SEL"
