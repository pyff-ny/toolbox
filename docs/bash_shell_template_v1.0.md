下面给你一套**可复用的 Bash 脚本模板（v1.0）**，专门适配你现在的风格：`toolbox_dir / source _lib / load_conf.sh / strict mode / 日志+收尾摘要 / dry-run / remote`。你以后新脚本基本就是“填空”。

---

## 1) 模板结构（你照这个抄，替换变量即可）

### A. Header / Bootstrap（所有脚本通用）

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

# -------------------------
# Identity
# -------------------------
SCRIPT_NAME="$(basename "$0")"
VERSION="v1.0"
RUN_TS="$(date +%Y%m%d_%H%M%S)"

# -------------------------
# Toolbox paths (robust)
# -------------------------
TOOLBOX_DIR="${TOOLBOX_DIR:-$HOME/toolbox}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$TOOLBOX_DIR/scripts}"
LIB_DIR="${LIB_DIR:-$TOOLBOX_DIR/_lib}"
OUT_DIR="${OUT_DIR:-$TOOLBOX_DIR/_out}"

# -------------------------
# Strict helpers
# -------------------------
die(){ echo "[ERROR] $*" >&2; exit 1; }

# -------------------------
# Load libs (log, rules, conf)
# -------------------------
RULES_SH="$LIB_DIR/rules.sh"
LOAD_CONF_SH="$LIB_DIR/load_conf.sh"

[[ -f "$RULES_SH" ]] || die "rules not found: $RULES_SH"
# shellcheck source=/dev/null
source "$RULES_SH"

[[ -f "$LOAD_CONF_SH" ]] || die "load_conf not found: $LOAD_CONF_SH"
# shellcheck source=/dev/null
source "$LOAD_CONF_SH"
```

> 你自己的 `rules.sh` 里如果已经有 `die/log_info/log_ok/log_warn/check_*`，这里就只负责 source。

---

### B. Config loading（每个脚本略有不同，但模式一致）

```bash
# -------------------------
# Config
# -------------------------
CONF_FILE="${1:-$TOOLBOX_DIR/ops/ssh_sync.env}"
[[ -f "$CONF_FILE" ]] || die "Config not found: $CONF_FILE"

log_info "LOCALLY" "Loading config: $CONF_FILE"
load_conf "$CONF_FILE"   # 你自己的实现：export 变量、校验必填等
```

> 如果你习惯用 `--conf` 参数，也可以把解析放在这里，但“统一入口”建议一直是 `CONF_FILE`。

---

### C. Inputs / defaults（严格模式下必须“先初始化再使用”）

```bash
# -------------------------
# Inputs / Defaults
# -------------------------
DRY_RUN="${DRY_RUN:-false}"
DO_DELETE="${DO_DELETE:-false}"

# 远端目标、路径等，按你脚本需要列出来
TARGET="${TARGET:-}"
REMOTE_REPORTS_DIR="${REMOTE_REPORTS_DIR:-IT-Reports}"
REMOTE_LOGS_DIR="${REMOTE_LOGS_DIR:-IT-Logs}"

LOCAL_REPORTS_DIR="${LOCAL_REPORTS_DIR:-$OUT_DIR/IT-Reports}"
LOCAL_LOGS_DIR="${LOCAL_LOGS_DIR:-$OUT_DIR/Logs}"

[[ -n "$TARGET" ]] || die "TARGET is required (in conf): e.g. user@host"
```

---

### D. Logging setup（统一日志文件输出）

```bash
# -------------------------
# Log file
# -------------------------
mkdir -p "$LOCAL_LOGS_DIR"
SYNC_LOG="$LOCAL_LOGS_DIR/${SCRIPT_NAME%.sh}_${RUN_TS}.log"

# 如果你有“tee到log”的机制，就在这里启用
# exec > >(tee -a "$SYNC_LOG") 2>&1
log_info "LOCALLY" "Log file: $SYNC_LOG"
```

---

### E. Preflight summary（你现在很成熟的那套“运行前声明”）

```bash
echo
log_info "LOCALLY" "RUN_ID: $RUN_TS"
log_info "LOCALLY" "DRY_RUN: $DRY_RUN"
log_info "LOCALLY" "DO_DELETE: $DO_DELETE"
log_info "REMOTE"  "Target: $TARGET"
log_info "LOCALLY" "Local reports: $LOCAL_REPORTS_DIR"
log_info "LOCALLY" "Local logs:    $LOCAL_LOGS_DIR"
log_info "REMOTE"  "Remote reports: $REMOTE_REPORTS_DIR"
log_info "REMOTE"  "Remote logs:    $REMOTE_LOGS_DIR"
echo
```

---

### F. Main work（脚本主体：你在这里写 rsync/ssh/生成报告等）

```bash
# -------------------------
# Main
# -------------------------
# TODO: your main logic here
# - preflight checks
# - rsync / ssh ops
# - snapshot paths computed
# - create reports/logs
```

---

### G. Snapshot index（你现在的“写 index 但 dry-run 不写”的范式）

```bash
# -------------------------
# Snapshot index (optional)
# -------------------------
SNAP_INDEX=""   # 关键：strict mode 下先初始化
SNAP_REPORTS="" # 同理
SNAP_LOGS=""

# 例：计算 snapshot dir（按你自己的逻辑）
# SNAP_ROOT_REMOTE="/Volumes/iMac_HDD_Backup/_snapshots/$RUN_TS"
# SNAP_REPORTS="$SNAP_ROOT_REMOTE/$REMOTE_REPORTS_DIR"
# SNAP_LOGS="$SNAP_ROOT_REMOTE/$REMOTE_LOGS_DIR"

if [[ "$DRY_RUN" != "true" ]]; then
  SNAP_INDEX="$SNAP_ROOT_REMOTE/index.tsv"

  INDEX_LINE="$(printf "RUN_ID=%s\tDRY_RUN=%s\tDO_DELETE=%s\tLOG=%s\tREPORTS=%s\tLOGS=%s\n" \
    "$RUN_TS" "$DRY_RUN" "$DO_DELETE" "$SYNC_LOG" "$SNAP_REPORTS" "$SNAP_LOGS")"

  ssh "$TARGET" "set -e; cat >> \"$SNAP_INDEX\" <<'EOF'
$INDEX_LINE
EOF"

  log_ok "REMOTE" "Snapshot index updated: $SNAP_INDEX"
else
  # 不写 index，仅说明
  :
fi
```

---

### H. Footer summary（你现在最终版的“收尾输出模板”）

```bash
# -------------------------
# Footer / Summary
# -------------------------
echo
log_ok   "LOCALLY" "DONE @ $RUN_TS"
log_info "LOCALLY" "Log file: $SYNC_LOG"
log_info "REMOTE"  "Remote snapshot dir: $SNAP_REPORTS , $SNAP_LOGS"
log_info "REMOTE"  "Remote snapshot index: ${SNAP_INDEX:-not written (dry-run)}"

if [[ "$DRY_RUN" == "true" ]]; then
  log_info "LOCALLY" "Dry-run completed successfully (no changes applied)."
else
  log_ok "LOCALLY" "Sync completed successfully."
fi

log_warn "If you encounter issues, please check the log file above."
exit 0
```

---

## 2) 你以后迁移别的脚本，只需要改的“填空区”

我把最常改的地方列成一个 checklist：

* [ ] 脚本身份：`SCRIPT_NAME / VERSION`
* [ ] 配置文件默认路径：`CONF_FILE=...`
* [ ] 必填变量校验：`TARGET / 关键路径 / 关键命令`
* [ ] 本地输出目录：`LOCAL_*_DIR`
* [ ] 远端逻辑目录名：`REMOTE_*_DIR`
* [ ] 主体逻辑：Main 部分
* [ ] 是否启用 snapshot index：G 部分（可选）
* [ ] 收尾输出是否需要 remote 字段：H 部分（按脚本用途删减）

---

## 3) 你现在这套风格的“铁律”（给你做脚本标准用）

1. **strict mode 下，所有可能引用的变量必须先初始化**（哪怕空字符串）
2. **运行前声明**（RUN_ID / flags / paths / target）
3. **收尾摘要**必须能让人不看 log 也知道干了啥
4. **dry-run 与 real-run 的成功语句必须分叉**（你已经做到）
5. **remote 副作用（写 index / delete）必须被 DRY_RUN 门控**

---

### English summary

Here’s a reusable Bash template matching your toolbox style: strict mode, robust TOOLBOX paths, sourcing `_lib` helpers, loading a `.env` config, printing a preflight context block, optional snapshot index writing gated by `DRY_RUN`, and a consistent footer summary. You can copy this skeleton and only fill in the “Main” section + variable names per script.
