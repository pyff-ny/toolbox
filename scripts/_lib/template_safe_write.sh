#!/usr/bin/env bash
#适用于 toolbox 里所有“会写文件”的脚本）：包含 严格模式 + 可控 debug + tmp guard + 原子写入 + 统一日志
#你在 bump 脚本里怎么用（最少改动）
#你那边核心流程就是：
#tmp="$(mktemp)"
#写入 tmp
#entry_prefix="#${NEXT_N}."（必须先定义）
#guard_prefix_in_file "$entry_prefix" "$tmp"
#atomic_write "$tmp" "$CHANGELOG_FILE"

set -Eeuo pipefail

# =========================
# 0) Basics
# =========================
die(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }

# 可选：统一 debug 开关（你现在已经用全局 DEBUG=1 了）
DEBUG="${DEBUG:-0}"         # 1=trace (set -x)
GUARD_DEBUG="${GUARD_DEBUG:-0}"  # 1=guard 失败时打印详细诊断

# =========================
# 1) Logging helpers (minimal)
# =========================
log_info(){ printf '[INFO] %s\n' "$*" >&2; }
log_warn(){ printf '[WARN] %s\n' "$*" >&2; }
log_ok(){   printf '[OK] %s\n'   "$*" >&2; }

# trace 控制：只在你想要时打开
if [[ "$DEBUG" == "1" ]]; then
  set -x
fi

# =========================
# 2) Temp file lifecycle
# =========================
mk_tmp() {
  local base="${1:-tmp}"
  mktemp "${TMPDIR:-/tmp}/${base}.XXXXXX"
}

cleanup_files=()
cleanup_add(){ cleanup_files+=("$1"); }

cleanup() {
  # 只清理自己创建的 tmp（避免误删）
  local f
  for f in "${cleanup_files[@]:-}"; do
    [[ -n "${f:-}" && -e "$f" ]] && rm -f "$f" || true
  done
}
trap cleanup EXIT

# =========================
# 3) Guard utilities (quiet by default)
# =========================
guard_prefix_in_file() {
  # args: prefix file
  local prefix="${1:?prefix}" file="${2:?file}"

  # 默认静音：即使全局 DEBUG=1，也不刷屏
  set +x

  if ! grep -qF "$prefix" "$file"; then
    echo "[ERROR] Refuse to write: prefix not found in tmp: $prefix" >&2

    if [[ "${GUARD_DEBUG:-0}" == "1" ]]; then
      echo "[DEBUG] tmp=$file" >&2
      echo "[DEBUG] first 60 lines of tmp:" >&2
      sed -n '1,60p' "$file" >&2 || true
    fi

    # 恢复 trace（可选）
    [[ "${DEBUG:-0}" == "1" ]] && set -x
    return 1
  fi

  # 恢复 trace（可选）
  [[ "${DEBUG:-0}" == "1" ]] && set -x
  return 0
}

guard_no_clobber_nonempty_to_empty() {
  # args: src dst
  local src="${1:?src}" dst="${2:?dst}"

  # dst 非空，但 src 为空 => 拒绝写入
  if [[ -s "$dst" && ! -s "$src" ]]; then
    die "Refuse to overwrite non-empty file with empty content: $dst"
  fi
}

atomic_write() {
  # args: src tmp_file dst_file
  local src="${1:?src}" dst="${2:?dst}"

  guard_no_clobber_nonempty_to_empty "$src" "$dst"
  mv -f "$src" "$dst"
}

# =========================
# 4) Example: "safe update file" pattern
# =========================
# 你在这里实现：读旧文件 -> 生成新内容到 tmp -> guard -> 原子 mv
safe_prepend_line() {
  # args: file line
  local file="${1:?file}" line="${2:?line}"

  mkdir -p "$(dirname "$file")"
  touch "$file"

  local tmp
  tmp="$(mk_tmp "write")"
  cleanup_add "$tmp"

  {
    printf '%s\n' "$line"
    cat "$file"
  } > "$tmp"

  # guard：确认写入目标行存在于 tmp
  # prefix 建议用稳定前缀（比如 "#123."），不要用整行避免空格/转义影响
  local prefix="${line%% *}"  # 取第一个 token 当 prefix；你也可以传入 entry_prefix 更严谨
  guard_prefix_in_file "$prefix" "$tmp" || die "tmp content unexpected (guard)."

  atomic_write "$tmp" "$file"
  log_ok "Updated file: $file"
}

# =========================
# 5) Main (demo)
# =========================
# safe_prepend_line "/tmp/demo.md" "#12. hello world"
