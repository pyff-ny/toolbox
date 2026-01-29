# /scripts/_lib/summary.sh
# shellcheck shell=bash
set -u

# ----------------------------
# Public API (你会用到的函数)
# ----------------------------
# summary_init
# summary_set_meta key value         # 可选：script/config/log/remote/source/destination等
# summary_set_note_path "/path/to/note.md"   # 可选：写入 Obsidian note
# summary_set_log_path  "/path/to/run.log"   # 可选：追加写入 log
# summary_begin_run "DRY"|"REAL" true|false  # run_mode + dry_run
# summary_set_metrics transferred_mb files_created files_deleted files_transferred elapsed_seconds elapsed_human
# summary_mark_cancelled                       # 可选：你也可以用 Ctrl-C trap 自动标记
# summary_wrap_cmd  <command ...>              # 建议：用它跑 rsync/命令，自动采集 RSYNC_CODE
# summary_finalize                             # 生成 SUMMARY / SUMMARY_JSON，必要时写 log/note
# summary_print_end_banner                     # 打印终端 END + SUMMARY + SUMMARY_JSON（可按需调用）

# ----------------------------
# Internals / state
# ----------------------------
SUMMARY_CANCELLED=0
SUMMARY_RSYNC_CODE=0
SUMMARY_EXIT_CODE=0
SUMMARY_STATUS="OK"
SUMMARY_CONF_PATH=""

SUMMARY_RUN_MODE=""      # "DRY" or "REAL"
SUMMARY_DRY_RUN=false    # true/false

# metrics default
SUMMARY_TRANSFERRED_MB="0.00"
SUMMARY_FILES_CREATED=0
SUMMARY_FILES_DELETED=0
SUMMARY_FILES_TRANSFERRED=0
SUMMARY_ELAPSED_SECONDS=0
SUMMARY_ELAPSED_HUMAN="00:00:00"

# meta
SUMMARY_TS=""            # e.g. 2026-01-27T03:02:52
SUMMARY_SCRIPT_PATH=""
SUMMARY_CONF_PATH=""
SUMMARY_LOG_ABS=""
SUMMARY_REMOTE=""
SUMMARY_SOURCE=""
SUMMARY_DESTINATION=""

# outputs
SUMMARY_LINE=""
SUMMARY_JSON=""

# sinks (optional)
SUMMARY_NOTE_PATH=""     # obsidian note file path
SUMMARY_APPEND_LOG_PATH="" # run log file path to append

# ----------------------------
# Helpers
# ----------------------------
_summary_now_iso() {
  # Prefer UTC Z if you want; here keep local ISO-like
  date +"%Y-%m-%dT%H:%M:%S"
}

_json_escape() {
  # Minimal JSON string escaper for common paths/text
  # Usage: _json_escape "$value"
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

_summary_trap_int() {
  SUMMARY_CANCELLED=1
  # 不要在这里 exit；让调用方决定是否“优雅收尾后退出”
}

# ----------------------------
# Public functions
# ----------------------------
summary_init() {
  SUMMARY_CANCELLED=0
  SUMMARY_RSYNC_CODE=0
  SUMMARY_EXIT_CODE=0
  SUMMARY_STATUS="OK"

  SUMMARY_RUN_MODE=""
  SUMMARY_DRY_RUN=false

  SUMMARY_TRANSFERRED_MB="0.00"
  SUMMARY_FILES_CREATED=0
  SUMMARY_FILES_DELETED=0
  SUMMARY_FILES_TRANSFERRED=0
  SUMMARY_ELAPSED_SECONDS=0
  SUMMARY_ELAPSED_HUMAN="00:00:00"

  SUMMARY_TS="$(_summary_now_iso)"

  SUMMARY_SCRIPT_PATH=""
  SUMMARY_CONF_PATH="${CONF_PATH:-${TOOLBOX_CONF_USED:-}}"
  SUMMARY_LOG_ABS=""

  SUMMARY_REMOTE=""
  SUMMARY_SOURCE=""
  SUMMARY_DESTINATION=""

  SUMMARY_LINE=""
  SUMMARY_JSON=""

  SUMMARY_NOTE_PATH=""
  SUMMARY_APPEND_LOG_PATH=""

  trap _summary_trap_int INT
}

summary_set_meta() {
  # summary_set_meta key value
  local k="${1:?missing key}"
  local v="${2-}"
  case "$k" in
    ts) SUMMARY_TS="$v" ;;
    script_path) SUMMARY_SCRIPT_PATH="$v" ;;
    conf_path) SUMMARY_CONF_PATH="$v" ;;
    log_abs) SUMMARY_LOG_ABS="$v" ;;
    remote) SUMMARY_REMOTE="$v" ;;
    source) SUMMARY_SOURCE="$v" ;;
    destination) SUMMARY_DESTINATION="$v" ;;
    *) return 1 ;;
  esac
}

summary_set_note_path() {
  SUMMARY_NOTE_PATH="${1-}"
}

summary_set_log_path() {
  SUMMARY_APPEND_LOG_PATH="${1-}"
}

summary_begin_run() {
  # summary_begin_run "DRY"/"REAL" true|false
  SUMMARY_RUN_MODE="${1:?missing run_mode}"
  SUMMARY_DRY_RUN="${2:-false}"
}

summary_set_metrics() {
  SUMMARY_TRANSFERRED_MB="${1:-0.00}"
  SUMMARY_FILES_CREATED="${2:-0}"
  SUMMARY_FILES_DELETED="${3:-0}"
  SUMMARY_FILES_TRANSFERRED="${4:-0}"
  SUMMARY_ELAPSED_SECONDS="${5:-0}"
  SUMMARY_ELAPSED_HUMAN="${6:-00:00:00}"
}

summary_mark_cancelled() {
  SUMMARY_CANCELLED=1
}

summary_wrap_cmd() {
  # 用它来跑 rsync/任意命令，自动采集退出码到 SUMMARY_RSYNC_CODE
  "$@"
  SUMMARY_RSYNC_CODE=$?
  return "$SUMMARY_RSYNC_CODE"
}

summary_finalize() {
  # 1) status + exit_code 归一化
  SUMMARY_STATUS="OK"
  SUMMARY_EXIT_CODE=$SUMMARY_RSYNC_CODE

  if (( SUMMARY_CANCELLED == 1 )); then
    SUMMARY_STATUS="CANCELLED"
    SUMMARY_EXIT_CODE=130
  elif (( SUMMARY_RSYNC_CODE == 24 )); then
    SUMMARY_STATUS="WARN(code24 vanished)"
    SUMMARY_EXIT_CODE=24
  elif (( SUMMARY_RSYNC_CODE == 23 )); then
    SUMMARY_STATUS="ERROR(code23 partial)"
    SUMMARY_EXIT_CODE=23
  elif (( SUMMARY_RSYNC_CODE != 0 )); then
    SUMMARY_STATUS="ERROR(code${SUMMARY_RSYNC_CODE})"
    SUMMARY_EXIT_CODE=$SUMMARY_RSYNC_CODE
  else
    SUMMARY_STATUS="OK"
    SUMMARY_EXIT_CODE=0
  fi

  # 2) SUMMARY_LINE（对外 code 用 EXIT_CODE；同时保留 rsync_code 仅在 JSON 中）
  # 你想要的字段都可以在这里统一
  SUMMARY_LINE=$(
    printf "SUMMARY | [%s] | status=%s | code=%d | dry_run=%s | transferred=%sMB | reg_xfer=%d | created=%d | deleted=%d | elapsed=%s | remote=%s | log=%s" \
      "${SUMMARY_RUN_MODE:-}" \
      "${SUMMARY_STATUS}" \
      "${SUMMARY_EXIT_CODE}" \
      "${SUMMARY_DRY_RUN}" \
      "${SUMMARY_TRANSFERRED_MB}" \
      "${SUMMARY_FILES_TRANSFERRED}" \
      "${SUMMARY_FILES_CREATED}" \
      "${SUMMARY_FILES_DELETED}" \
      "${SUMMARY_ELAPSED_HUMAN}" \
      "${SUMMARY_REMOTE}" \
      "$(basename -- "${SUMMARY_LOG_ABS:-${SUMMARY_APPEND_LOG_PATH:-}}")"
  )

  # 3) SUMMARY_JSON（code=EXIT_CODE，rsync_code=RSYNC_CODE）
  local j_status j_ts j_script j_conf j_log j_remote j_src j_dst
  j_status="$(_json_escape "$SUMMARY_STATUS")"
  j_ts="$(_json_escape "$SUMMARY_TS")"
  j_script="$(_json_escape "$SUMMARY_SCRIPT_PATH")"
  j_conf="$(_json_escape "$SUMMARY_CONF_PATH")"
  j_log="$(_json_escape "${SUMMARY_LOG_ABS:-$SUMMARY_APPEND_LOG_PATH}")"
  j_remote="$(_json_escape "$SUMMARY_REMOTE")"
  j_src="$(_json_escape "$SUMMARY_SOURCE")"
  j_dst="$(_json_escape "$SUMMARY_DESTINATION")"

  SUMMARY_JSON=$(cat <<EOF
{
  "status": "${j_status}",
  "code": ${SUMMARY_EXIT_CODE},
  "rsync_code": ${SUMMARY_RSYNC_CODE},
  "dry_run": ${SUMMARY_DRY_RUN},
  "transferred_mb": ${SUMMARY_TRANSFERRED_MB},
  "files_created": ${SUMMARY_FILES_CREATED},
  "files_deleted": ${SUMMARY_FILES_DELETED},
  "files_transferred": ${SUMMARY_FILES_TRANSFERRED},
  "elapsed_seconds": ${SUMMARY_ELAPSED_SECONDS},
  "elapsed_human": "$(_json_escape "$SUMMARY_ELAPSED_HUMAN")",
  "log": "${j_log}",
  "timestamp": "${j_ts}",
  "script": "${j_script}",
  "config": "${j_conf}",
  "remote": "${j_remote}",
  "source": "${j_src}",
  "destination": "${j_dst}"
}
EOF
)

  # 4) append to run log（可选）
  if [[ -n "${SUMMARY_APPEND_LOG_PATH:-}" ]]; then
    {
      echo
      echo "=============================="
      echo "$SUMMARY_LINE"
      echo "=============================="
      echo "[SUMMARY_JSON] $SUMMARY_JSON"
    } >> "$SUMMARY_APPEND_LOG_PATH" 2>/dev/null || true
  fi

  # 5) append to Obsidian note（可选）
  if [[ -n "${SUMMARY_NOTE_PATH:-}" ]]; then
    mkdir -p "$(dirname -- "$SUMMARY_NOTE_PATH")" 2>/dev/null || true
    {
      echo
      echo "## RSYNC Backup Run — ${SUMMARY_TS}"
      echo
      [[ -n "$SUMMARY_SCRIPT_PATH" ]] && echo "**Script**: $SUMMARY_SCRIPT_PATH"
      [[ -n "$SUMMARY_CONF_PATH" ]] && echo "**Config**: $SUMMARY_CONF_PATH"
      [[ -n "${SUMMARY_LOG_ABS:-$SUMMARY_APPEND_LOG_PATH}" ]] && echo "**Log**: ${SUMMARY_LOG_ABS:-$SUMMARY_APPEND_LOG_PATH}"
      echo
      echo "_${SUMMARY_LINE}_"
      echo
      echo '```json'
      printf '%s\n' "$SUMMARY_JSON"
      echo '```'
      echo
      echo "---"
    } >> "$SUMMARY_NOTE_PATH"
  fi
}

summary_print_end_banner() {
  # 仅负责终端输出；不写文件
  echo "===== RSYNC BACKUP END ====="
  echo "Time: ${SUMMARY_TS}"
  [[ -n "$SUMMARY_SCRIPT_PATH" ]] && echo "[INFO] Script: $SUMMARY_SCRIPT_PATH"
  [[ -n "$SUMMARY_CONF_PATH" ]] && echo "[INFO] Config: $SUMMARY_CONF_PATH"
  [[ -n "${SUMMARY_LOG_ABS:-$SUMMARY_APPEND_LOG_PATH}" ]] && echo "[INFO] Log: ${SUMMARY_LOG_ABS:-$SUMMARY_APPEND_LOG_PATH}"
  echo "=============================="
  echo "$SUMMARY_LINE"
  echo "=============================="
  echo "[SUMMARY_JSON] $SUMMARY_JSON"
}
