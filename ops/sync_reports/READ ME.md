READ ME 


这版已经非常接近“最终可交付版”了，**快照 + dry-run 不落盘**都做对了。
但还差一个**结构性收口点**（很关键）：

> 你现在是 **先解析 CLI（--dry-run/--real/--delete）**，然后才 `source "$CFG"`
> 如果你的 `ssh_sync.conf` 里未来写了 `DRY_RUN=` 或 `DO_DELETE=`，它会**覆盖你刚解析好的 CLI 值**。

为了让行为“永远符合直觉”，顺序应该是：

✅ **先 source 配置**（拿到默认值）
✅ **再 CLI override**（最终权威）
✅ **再做 delete 二次确认**（基于最终值）

---

# ✅ 你应该怎么改（只改顺序，不改逻辑）

下面我给你一份“最终版”结构（你直接整段覆盖即可）：

```bash
#!/usr/bin/env bash
set -euo pipefail

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
ts(){ date +"%Y%m%d_%H%M%S"; }

ROOT="${TOOLBOX_ROOT:-$HOME/toolbox}"
CONF_DIR="${CONF_DIR:-$ROOT/conf}"
CFG="${CFG:-$CONF_DIR/ssh_sync.conf}"

LOG_DIR="${LOG_DIR:-$HOME/Logs}"
mkdir -p "$CONF_DIR" "$LOG_DIR"

[[ -f "$CFG" ]] || die "Missing config: $CFG"
# shellcheck disable=SC1090
source "$CFG"

# defaults from conf (fallback if missing in conf)
DRY_RUN="${DRY_RUN:-false}"
DO_DELETE="${DO_DELETE:-false}"

# CLI override (final authority)
for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=true ;;
    --real)      DRY_RUN=false ;;
    --delete)    DO_DELETE=true ;;
    --no-delete) DO_DELETE=false ;;
    -h|--help)
      echo "Usage: sync_reports [--dry-run|--real] [--delete|--no-delete]"
      exit 0
      ;;
    *)
      die "Unknown arg: $arg"
      ;;
  esac
done

# delete safety confirm (based on FINAL values)
if [[ "$DO_DELETE" == "true" && "$DRY_RUN" != "true" ]]; then
  read -r -p "Type YES to confirm DELETE sync: " ans
  [[ "$ans" == "YES" ]] || { echo "Cancelled."; exit 1; }
fi

: "${SSH_HOST:?SSH_HOST is required in $CFG}"
: "${LOCAL_REPORTS:?LOCAL_REPORTS is required in $CFG}"
: "${LOCAL_LOGS:?LOCAL_LOGS is required in $CFG}"
: "${REMOTE_REPORTS:?REMOTE_REPORTS is required in $CFG}"
: "${REMOTE_LOGS:?REMOTE_LOGS is required in $CFG}"

TARGET="$SSH_HOST"
if [[ -n "${SSH_USER:-}" && "$SSH_HOST" != *"@"* ]]; then
  TARGET="${SSH_USER}@${SSH_HOST}"
fi

command -v rsync >/dev/null 2>&1 || die "rsync not found"
command -v ssh   >/dev/null 2>&1 || die "ssh not found"

# rotate old logs
find "$LOG_DIR" -type f -name 'sync_reports_*.log' -mtime +30 -delete 2>/dev/null || true

SYNC_LOG="$LOG_DIR/sync_reports_$(ts).log"
exec > >(tee -a "$SYNC_LOG") 2>&1

echo "== Sync Reports + Logs to iMac (SSH) =="
echo "Time: $(date)"
echo "Config: $CFG"
echo "Target: $TARGET"
echo "Local reports:  $LOCAL_REPORTS"
echo "Local logs:     $LOCAL_LOGS"
echo "Remote reports: $REMOTE_REPORTS"
echo "Remote logs:    $REMOTE_LOGS"
echo "DRY_RUN:    $DRY_RUN"
echo "DO_DELETE:  $DO_DELETE"
echo "Log file: $SYNC_LOG"
echo

mkdir -p "$LOCAL_REPORTS" "$LOCAL_LOGS"

# quick ssh preflight (avoid hang)
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$TARGET" "echo ok" >/dev/null 2>&1; then
  echo "SSH preflight failed (needs manual first-time auth?)."
  echo "Run once manually: ssh $TARGET"
  exit 4
fi

# ensure remote dirs exist
ssh "$TARGET" "mkdir -p \"$REMOTE_REPORTS\" \"$REMOTE_LOGS\""

RSYNC_ARGS=(-az --human-readable --progress)
[[ "$DRY_RUN" == "true"  ]] && RSYNC_ARGS+=(--dry-run --itemize-changes)
[[ "$DO_DELETE" == "true" ]] && RSYNC_ARGS+=(--delete)

# snapshot/rollback
SNAP_ROOT_REMOTE="${SNAP_ROOT_REMOTE:-/Volumes/iMac_HDD_Backup/_snapshots}"
SNAP_TS="$(ts)"
SNAP_REPORTS="$SNAP_ROOT_REMOTE/$SNAP_TS/IT-Reports"
SNAP_LOGS="$SNAP_ROOT_REMOTE/$SNAP_TS/IT-Logs"

# only create snapshot dir on REAL run
if [[ "$DRY_RUN" != "true" ]]; then
  ssh "$TARGET" "mkdir -p \"$SNAP_REPORTS\" \"$SNAP_LOGS\""
fi

run_rsync() {
  local src="$1" dest="$2" backup_dir="$3"
  echo
  echo "[RSYNC] $src -> $dest"
  set +e
  if [[ "$DRY_RUN" == "true" ]]; then
    rsync "${RSYNC_ARGS[@]}" "$src" "$dest"
  else
    rsync "${RSYNC_ARGS[@]}" --backup --backup-dir="$backup_dir" "$src" "$dest"
  fi
  local rc=$?
  set -e
  return $rc
}

run_rsync "$LOCAL_REPORTS"/ "$TARGET":"$REMOTE_REPORTS"/ "$SNAP_REPORTS" || die "Reports sync failed"
run_rsync "$LOCAL_LOGS"/    "$TARGET":"$REMOTE_LOGS"/    "$SNAP_LOGS"    || die "Logs sync failed"

# keep snapshots 30 days
ssh "$TARGET" "find \"$SNAP_ROOT_REMOTE\" -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} \; 2>/dev/null || true"

echo
echo "DONE @ $(ts)"
echo "Log saved: $SYNC_LOG"
```

---

# ✅ 你这版“最终版”会带来的真实收益

1. **配置文件只负责默认值**（迁移时不改脚本）
2. **命令行参数永远优先**（符合直觉，`--dry-run` 一定生效）
3. **delete 二次确认一定准确**（不会被 conf 覆盖绕过去）

---

# ✅ 你现在的使用方式（固定 SOP）

```bash
sync_reports --dry-run
sync_reports --real
sync_reports --dry-run --delete
sync_reports --real --delete
```

---

## English summary

Your script is almost production-ready. The key fix is ordering: source the config first (defaults), then apply CLI overrides (`--dry-run/--real/--delete`), then run the delete confirmation based on the final values. This prevents the config from overriding command-line intent.

如果你愿意，我还可以帮你补一个“恢复命令提示”：每次 real run 结束时打印本次快照目录路径，方便你以后回滚时直接复制路径去 Finder 里找。
