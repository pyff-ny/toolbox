#!/usr/bin/env bash
# load_conf.sh - 统一配置加载器

TOOLBOX_ROOT="${TOOLBOX_ROOT:-$HOME/toolbox}"
CONF_DIR="${TOOLBOX_ROOT}/conf"

# 加载模块配置
load_module_conf() {
  local module="$1"
  local conf_file="${CONF_DIR}/${module}.env"
  
  if [[ -f "$conf_file" ]]; then
    echo "[INFO] Loading config: $conf_file" >&2
    # shellcheck source=/dev/null
    source "$conf_file"
  else
    echo "[WARN] Config file not found: $conf_file" >&2
    echo "[WARN] Using default values or environment variables" >&2
  fi
}

# 设置默认值
set_defaults() {
  # 通用配置
  TOOLBOX_ROOT="${TOOLBOX_ROOT:-$HOME/toolbox}"
  SCRIPTS_DIR="${SCRIPTS_DIR:-$TOOLBOX_ROOT/scripts}"
  LOG_DIR="${LOG_DIR:-$TOOLBOX_ROOT/Logs}"
  CONF_DIR="${CONF_DIR:-$TOOLBOX_ROOT/conf}"
  
  # 备份配置默认值
  SNAPSHOT_DIR="${SNAPSHOT_DIR:-$HOME/Backup/snapshots}"
  
  # 导出变量
  export TOOLBOX_ROOT SCRIPTS_DIR LOG_DIR CONF_DIR SNAPSHOT_DIR
}

# 初始化
set_defaults