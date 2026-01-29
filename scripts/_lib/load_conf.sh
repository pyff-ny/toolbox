#!/usr/bin/env bash
# load_conf.sh - 统一配置加载器（模板可见 + 本机可跑 + 不会误同步）

set -Eeuo pipefail

# -------- logging helpers --------
info(){ echo "[INFO] $*" >&2; }
warn(){ echo "[WARN] $*" >&2; }
err(){  echo "[ERROR] $*" >&2; }

# -------- defaults --------
set_defaults() {
  # 通用配置
  TOOLBOX_DIR="${TOOLBOX_DIR:-$HOME/toolbox}"
  SCRIPTS_DIR="${SCRIPTS_DIR:-$TOOLBOX_DIR/scripts}"

  # 建议：产物目录用小写 logs，更通用；但你已有 Logs 也没问题
  LOG_DIR="${LOG_DIR:-$TOOLBOX_DIR/_out/Logs}"
  CONF_DIR="${CONF_DIR:-$TOOLBOX_DIR/conf}"
  OPS_DIR="${OPS_DIR:-$TOOLBOX_DIR/ops}"

  # 备份配置默认值
  SNAPSHOT_DIR="${SNAPSHOT_DIR:-$HOME/Backup/snapshots}"

  export TOOLBOX_DIR SCRIPTS_DIR LOG_DIR CONF_DIR OPS_DIR SNAPSHOT_DIR
}

# -------- internal: pick config path --------
# 查找顺序（越靠前优先级越高）：
#  1) TOOLBOX_CONF：显式指定绝对路径
#  2) ops/<module>.env：本机运行态（推荐）
#  3) ~/.config/toolbox/<module>.env：用户级配置
#  4) ~/.toolbox/<module>.env：legacy
#
# 模板路径：
#  conf/<module>.env.example  或 conf/<module>.example.env 或 conf/<module>.env
#
pick_module_conf() {
  local module="$1"

  local explicit="${TOOLBOX_CONF:-}"
  local c_ops="${OPS_DIR}/${module}.env"
  local c_xdg="${XDG_CONFIG_HOME:-$HOME/.config}/toolbox/${module}.env"
  local c_legacy="$HOME/.toolbox/${module}.env"

  local picked=""
  if [[ -n "$explicit" && -f "$explicit" ]]; then
    picked="$explicit"
  elif [[ -f "$c_ops" ]]; then
    picked="$c_ops"
  elif [[ -f "$c_xdg" ]]; then
    picked="$c_xdg"
  elif [[ -f "$c_legacy" ]]; then
    picked="$c_legacy"
  fi

  printf "%s" "$picked"
}

pick_module_template() {
  local module="$1"

  local t1="${CONF_DIR}/${module}.env.example"
  local t2="${CONF_DIR}/${module}.example.env"
  local t3="${CONF_DIR}/${module}.env"   # 兼容你原本的命名；建议未来改成 example

  if [[ -f "$t1" ]]; then printf "%s" "$t1"; return 0; fi
  if [[ -f "$t2" ]]; then printf "%s" "$t2"; return 0; fi
  if [[ -f "$t3" ]]; then printf "%s" "$t3"; return 0; fi
  printf "%s" ""
}

# -------- internal: validate required vars --------
validate_required_vars() {
  local conf_path="$1"; shift || true
  local vars=("$@")

  local v
  for v in "${vars[@]}"; do
    if [[ -z "${!v:-}" ]]; then
      err "Config '$conf_path' missing required var: $v"
      return 3
    fi
  done
  return 0
}

# -------- public: load module config --------
# 用法：
#   load_module_conf "backup" "SRC_DIR" "DST_DIR"
#   load_module_conf "disk_health"
#
# 行为：
# - 优先加载 ops/ 或用户配置
# - 找不到则提示从 conf/ 模板复制生成
# - 可选校验必填变量
#
load_module_conf() {
  local module="$1"; shift || true
  local required_vars=("$@")

  local conf_path template
  conf_path="$(pick_module_conf "$module")"
  template="$(pick_module_template "$module")"

  if [[ -n "$conf_path" ]]; then
    info "Loading config: $conf_path"
    # shellcheck source=/dev/null
    source "$conf_path"

    if (( ${#required_vars[@]} > 0 )); then
      validate_required_vars "$conf_path" "${required_vars[@]}"
    fi
    export TOOLBOX_CONF_USED="$conf_path"

    return 0
  fi

  warn "Config file not found for module '$module'."
  if [[ -n "$template" ]]; then
    cat >&2 <<EOF
[HINT] Create a real config (NOT tracked by git) from template:

  mkdir -p "$OPS_DIR"
  cp "$template" "$OPS_DIR/${module}.env"
  ${EDITOR_CMD:-nano} "$OPS_DIR/${module}.env"

Then rerun.
EOF
  else
    cat >&2 <<EOF
[HINT] Create a real config at one of these locations:
  - "$OPS_DIR/${module}.env"
  - "${XDG_CONFIG_HOME:-$HOME/.config}/toolbox/${module}.env"
  - "$HOME/.toolbox/${module}.env"
Or set:
  TOOLBOX_CONF=/absolute/path/to/${module}.env
EOF
  fi

  # 返回码 2：缺配置（方便上层决定是否退出）
  return 2
}

# 初始化
set_defaults
