#!/usr/bin/env bash
set -euo pipefail

TOOLBOX_DIR="${TOOLBOX_DIR:-$HOME/toolbox}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$TOOLBOX_DIR/scripts}"
BIN_DIR="${BIN_DIR:-$TOOLBOX_DIR/bin}"

MAX_DEPTH="${MAX_DEPTH:-3}"

die() { echo "[ERROR] $*" 1>&2; exit 1; }
has_fzf() { command -v fzf >/dev/null 2>&1; }

[[ -d "$SCRIPTS_DIR" ]] || die "SCRIPTS_DIR not found: $SCRIPTS_DIR"
has_fzf || die "fzf not found. Install with: brew install fzf"

# ---------- 基础：列出脚本 ----------
# 输出：relative_path<TAB>abs_path
list_scripts() {
  find "$SCRIPTS_DIR" -maxdepth "$MAX_DEPTH" -type f -print0 \
  | while IFS= read -r -d '' f; do
      rel="${f#$SCRIPTS_DIR/}"
      # 跳过隐藏文件/README
      [[ "$(basename "$rel")" =~ ^\. ]] && continue
      [[ "$rel" =~ README ]] && continue
      echo -e "${rel}\t${f}"
    done
}

# rel -> category/sub/script
# category: 第一段（如果无 / 则 Root）
get_category() {
  local rel="$1"
  if [[ "$rel" == *"/"* ]]; then
    echo "${rel%%/*}"
  else
    echo "Root"
  fi
}

# rel -> sub（第二段），若没有则 "(none)"
get_sub() {
  local rel="$1"
  # Root 直接 none
  if [[ "$rel" != *"/"* ]]; then
    echo "(none)"
    return
  fi
  # 去掉 category/
  local rest="${rel#*/}"
  if [[ "$rest" == *"/"* ]]; then
    echo "${rest%%/*}"
  else
    echo "(none)"
  fi
}

# rel -> filename (最后一段)
get_filename() {
  local rel="$1"
  echo "${rel##*/}"
}

# rel -> wrapper 名：
# - 如果在 Root：basename 去后缀
# - 如果在子目录：相对路径去后缀，再把 / 替换成 __
rel_to_cmd() {
  local rel="$1"
  local noext="${rel%.*}"
  if [[ "$rel" == *"/"* ]]; then
    echo "${noext//\//__}"
  else
    echo "${noext}"
  fi
}

# ---------- preview ----------
preview_file() {
  local abs="$1"
  echo "FILE: $abs"
  echo "------------------------------------------------------------"
  # 展示前 80 行，足够形成“预览感”
  sed -n '1,80p' "$abs" 2>/dev/null || true
}

# ---------- 执行 ----------
run_script() {
  local rel="$1"
  local abs="$2"

  local cmd
  cmd="$(rel_to_cmd "$rel")"
  local wrapper="$BIN_DIR/$cmd"

  echo
  echo "[RUN] $cmd"
  echo

  if [[ -x "$wrapper" ]]; then
    exec "$wrapper"
  fi

  # fallback：直接跑脚本（一般不会用到，因为你有 wrappers）
  case "$abs" in
    *.py) exec python3 "$abs" ;;
    *.sh) exec bash "$abs" ;;
    *)    exec "$abs" ;;
  esac
}

# ---------- UI：fzf ----------
pick_one() {
  local prompt="$1"
  shift
  # stdin 输入候选项；输出选中项（整行）
  fzf --prompt="$prompt " \
      --height=60% --layout=reverse --border \
      --no-multi \
      --preview='bash -c "preview_file \"{2}\"" ' \
      --preview-window=right:60%:wrap \
      --delimiter=$'\t' \
      --with-nth=1
}

export -f preview_file

# ---------- 主流程 ----------
main() {
  echo
  echo "[INFO] TOOLBOX_DIR : $TOOLBOX_DIR"
  echo "[INFO] SCRIPTS_DIR : $SCRIPTS_DIR"
  echo "[INFO] BIN_DIR     : $BIN_DIR"
  echo

  # 预读全部脚本（rel<TAB>abs）
  mapfile_tmp="$(mktemp)"
  list_scripts > "$mapfile_tmp"

  # 没脚本就退出
  if [[ ! -s "$mapfile_tmp" ]]; then
    echo "[INFO] no scripts found in $SCRIPTS_DIR"
    rm -f "$mapfile_tmp"
    exit 0
  fi

  while true; do
    # ---------- 一级：Category ----------
    # 构造分类列表：category<TAB>dummy_abs
    cat_tmp="$(mktemp)"
    awk -F'\t' '{print $1}' "$mapfile_tmp" \
      | while IFS= read -r rel; do
          get_category "$rel"
        done \
      | sort -u \
      | while IFS= read -r c; do
          # dummy_abs 用 scripts 目录本身，保证 preview 有内容
          echo -e "${c}\t${SCRIPTS_DIR}"
        done > "$cat_tmp"

    selected_cat_line="$(cat "$cat_tmp" | fzf --prompt="Root / (none) > " \
      --height=60% --layout=reverse --border \
      --no-multi \
      --preview='bash -c "echo CATEGORY: {1}; echo; ls -la \"'"$SCRIPTS_DIR"'\" | sed -n \"1,50p\""' \
      --preview-window=right:60%:wrap \
      --delimiter=$'\t' --with-nth=1 )" || true

    rm -f "$cat_tmp"

    [[ -z "${selected_cat_line:-}" ]] && break
    selected_cat="$(echo "$selected_cat_line" | cut -f1)"

    # ---------- 二级：Sub / Commands ----------
    # 过滤出该 category 下的脚本
    filtered_tmp="$(mktemp)"
    awk -F'\t' -v CAT="$selected_cat" '
      {
        rel=$1; abs=$2;
        # category 判定
        split(rel, a, "/");
        cat=(index(rel,"/")>0)?a[1]:"Root";
        if (cat==CAT) print rel "\t" abs;
      }
    ' "$mapfile_tmp" > "$filtered_tmp"

    # 构造二级条目：
    # - 如果有 subdir，则列 subdir
    # - 同时列本层 script（sub == (none) 的脚本）
    level2_tmp="$(mktemp)"

    # subdir entries
    awk -F'\t' '{print $1}' "$filtered_tmp" \
      | while IFS= read -r rel; do
          get_sub "$rel"
        done \
      | sort -u \
      | while IFS= read -r sub; do
          if [[ "$sub" != "(none)" ]]; then
            echo -e "${sub}\t${SCRIPTS_DIR}/${selected_cat}/${sub}"
          fi
        done > "$level2_tmp"

    # scripts directly under category (sub == none) 也加入 level2
    awk -F'\t' '{print $1 "\t" $2}' "$filtered_tmp" \
      | while IFS=$'\t' read -r rel abs; do
          sub="$(get_sub "$rel")"
          if [[ "$sub" == "(none)" ]]; then
            # 显示文件名，但保留 rel/abs 用于执行
            echo -e "$(get_filename "$rel")\t${abs}\t${rel}" >> "$level2_tmp"
          fi
        done

    # 如果 category 是 Root：直接列 Root 下脚本作为 level2
    if [[ "$selected_cat" == "Root" ]]; then
      : > "$level2_tmp"
      awk -F'\t' '{print $1 "\t" $2}' "$filtered_tmp" \
        | while IFS=$'\t' read -r rel abs; do
            echo -e "$(get_filename "$rel")\t${abs}\t${rel}" >> "$level2_tmp"
          done
    fi

    # 二级 fzf
    if [[ "$selected_cat" == "Root" ]]; then
      # Root 没三级，直接执行
      picked2="$(cat "$level2_tmp" | fzf --prompt="Root > " \
        --height=60% --layout=reverse --border \
        --no-multi \
        --preview='bash -c "preview_file \"{2}\"" ' \
        --preview-window=right:60%:wrap \
        --delimiter=$'\t' --with-nth=1 )" || true

      rm -f "$filtered_tmp" "$level2_tmp"
      [[ -z "${picked2:-}" ]] && continue

      abs="$(echo "$picked2" | cut -f2)"
      rel="$(echo "$picked2" | cut -f3)"
      run_script "$rel" "$abs"
      exit 0
    fi

    picked2="$(cat "$level2_tmp" | fzf --prompt="${selected_cat} > " \
      --height=60% --layout=reverse --border \
      --no-multi \
      --preview='bash -c "preview_file \"{2}\"" ' \
      --preview-window=right:60%:wrap \
      --delimiter=$'\t' --with-nth=1 )" || true

    [[ -z "${picked2:-}" ]] && { rm -f "$filtered_tmp" "$level2_tmp"; continue; }

    # 判断 picked2 是 subdir 还是脚本：
    # - subdir 行：只有2列 (name<TAB>path)
    # - script 行：有3列 (filename<TAB>abs<TAB>rel)
    col_count="$(echo "$picked2" | awk -F'\t' '{print NF}')"

    if [[ "$col_count" -ge 3 ]]; then
      abs="$(echo "$picked2" | cut -f2)"
      rel="$(echo "$picked2" | cut -f3)"
      rm -f "$filtered_tmp" "$level2_tmp"
      run_script "$rel" "$abs"
      exit 0
    fi

    selected_sub="$(echo "$picked2" | cut -f1)"

    # ---------- 三级：Commands in sub ----------
    level3_tmp="$(mktemp)"
    awk -F'\t' -v CAT="$selected_cat" -v SUB="$selected_sub" '
      {
        rel=$1; abs=$2;
        # rel: CAT/SUB/...
        split(rel, a, "/");
        if (a[1]==CAT && a[2]==SUB) {
          print a[length(a)] "\t" abs "\t" rel
        }
      }
    ' "$mapfile_tmp" > "$level3_tmp"

    picked3="$(cat "$level3_tmp" | fzf --prompt="${selected_cat}/${selected_sub} > " \
      --height=60% --layout=reverse --border \
      --no-multi \
      --preview='bash -c "preview_file \"{2}\"" ' \
      --preview-window=right:60%:wrap \
      --delimiter=$'\t' --with-nth=1 )" || true

    rm -f "$filtered_tmp" "$level2_tmp"

    [[ -z "${picked3:-}" ]] && { rm -f "$level3_tmp"; continue; }

    abs="$(echo "$picked3" | cut -f2)"
    rel="$(echo "$picked3" | cut -f3)"
    rm -f "$level3_tmp"
    run_script "$rel" "$abs"
    exit 0
  done

  rm -f "$mapfile_tmp"
}

main "$@"
