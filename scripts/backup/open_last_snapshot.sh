#!/usr/bin/env bash
set -euo pipefail

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

ROOT="${TOOLBOX_ROOT:-$HOME/toolbox}"
LOG_DIR="${LOG_DIR:-$HOME/Logs}"
LOCAL_INDEX="${LOCAL_INDEX:-$LOG_DIR/snapshot_index.tsv}"

# 远端 open 需要用到（可从 ssh_sync.conf 继承）
CONF_DIR="${CONF_DIR:-$ROOT/conf}"
CFG="${CFG:-$CONF_DIR/ssh_sync.conf}"

# -------------------------
# 基础检查
# -------------------------
[[ -f "$LOCAL_INDEX" ]] || die "snapshot index not found: $LOCAL_INDEX"

# 读取最后一条记录
LAST_LINE="$(tail -n 1 "$LOCAL_INDEX" 2>/dev/null || true)"
[[ -n "$LAST_LINE" ]] || die "snapshot index empty: $LOCAL_INDEX"

getv() {
  local key="$1"
  echo "$LAST_LINE" | tr '\t' '\n' | sed -n "s/^${key}=//p"
}

RUN_ID="$(getv RUN_ID)"
DRY_RUN="$(getv DRY_RUN)"
REPORTS="$(getv REPORTS)"
LOGS="$(getv LOGS)"
LOG_FILE="$(getv LOG)"

DRY_RUN="${DRY_RUN:-unknown}"

echo "== Open Last Snapshot =="
echo "RUN_ID:   ${RUN_ID:-N/A}"
echo "DRY_RUN:  ${DRY_RUN}"
echo "REPORTS:  ${REPORTS:-N/A}"
echo "LOGS:     ${LOGS:-N/A}"
echo "LOG FILE: ${LOG_FILE:-N/A}"
echo

# -------------------------
# DRY_RUN = true → 不存在快照目录，不做 ssh open
# -------------------------
if [[ "$DRY_RUN" == "true" ]]; then
  echo "[INFO] This run was DRY_RUN=true, so no snapshot directory was created."
  echo "[INFO] Skip opening iMac snapshot dirs."

  if [[ -n "${LOG_FILE:-}" && -f "$LOG_FILE" ]]; then
    open "$LOG_FILE" >/dev/null 2>&1 || true
    echo "[OK] Opened local log: $LOG_FILE"
  else
    echo "[WARN] Local log not found: ${LOG_FILE:-<empty>}"
  fi

  exit 0
fi

# -------------------------
# REAL RUN：打开本地 log + 本地快照路径（如果存在）
# -------------------------
if [[ -n "${LOG_FILE:-}" && -f "$LOG_FILE" ]]; then
  open "$LOG_FILE" >/dev/null 2>&1 || true
  echo "[OK] Opened local log: $LOG_FILE"
else
  echo "[WARN] Local log not found: ${LOG_FILE:-<empty>}"
fi

if [[ -n "${REPORTS:-}" && -d "$REPORTS" ]]; then
  open "$REPORTS" >/dev/null 2>&1 || true
  echo "[OK] Opened snapshot Reports: $REPORTS"
else
  echo "[WARN] Reports dir missing locally: ${REPORTS:-<empty>}"
fi

if [[ -n "${LOGS:-}" && -d "$LOGS" ]]; then
  open "$LOGS" >/dev/null 2>&1 || true
  echo "[OK] Opened snapshot Logs: $LOGS"
else
  echo "[WARN] Logs dir missing locally: ${LOGS:-<empty>}"
fi

# -------------------------
# 可选：ssh 打开 iMac 上的快照目录
#   - 仅当本地目录缺失时才尝试 ssh open（避免重复弹窗）
# -------------------------
NEED_REMOTE_OPEN=0
[[ -n "${REPORTS:-}" && ! -d "$REPORTS" ]] && NEED_REMOTE_OPEN=1
[[ -n "${LOGS:-}"    && ! -d "$LOGS"    ]] && NEED_REMOTE_OPEN=1

if [[ "$NEED_REMOTE_OPEN" -eq 0 ]]; then
  echo "[INFO] Snapshot dirs exist locally; no need to SSH open."
  echo "DONE"
  exit 0
fi

# 从配置里拿 SSH_HOST/SSH_USER（如果配置存在）
if [[ -f "$CFG" ]]; then
  # shellcheck disable=SC1090
  source "$CFG"
fi

: "${SSH_HOST:?SSH_HOST is required in $CFG to SSH open remote snapshot dirs}"

TARGET="$SSH_HOST"
if [[ -n "${SSH_USER:-}" && "$SSH_HOST" != *"@"* ]]; then
  TARGET="${SSH_USER}@${SSH_HOST}"
fi

# ssh 预检
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$TARGET" "echo ok" >/dev/null 2>&1; then
  echo "[WARN] SSH preflight failed. Skip remote open."
  echo "Tip: run once manually: ssh $TARGET"
  echo "DONE"
  exit 0
fi

# 真正 remote open：在 iMac 上打开 Finder 指定目录
# (macOS 的 open 命令在远端执行)
if [[ -n "${REPORTS:-}" ]]; then
  ssh "$TARGET" "open \"$REPORTS\" >/dev/null 2>&1 || true" || true
  echo "[OK] Requested iMac open Reports: $REPORTS"
fi

if [[ -n "${LOGS:-}" ]]; then
  ssh "$TARGET" "open \"$LOGS\" >/dev/null 2>&1 || true" || true
  echo "[OK] Requested iMac open Logs: $LOGS"
fi

echo "DONE"
