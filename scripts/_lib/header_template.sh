#!/usr/bin/env bash
set -Eeuo pipefail

# ---------- Basics ----------
die() { echo "[ERROR] $*" >&2; exit 1; }
warn(){ echo "[WARN]  $*" >&2; }
info(){ echo "[INFO]  $*" >&2; }

# robust script root (works even if invoked via symlink/wrapper sometimes)
SCRIPT_DIR="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P
)"

# ---------- Load libs ----------
TOOLBOX_DIR="${TOOLBOX_DIR:-$HOME/toolbox}"
LIB_DIR="$TOOLBOX_DIR/scripts/_lib"

[[ -f "$TOOLBOX_DIR/_lib/rules.sh" ]] || die "rules.sh not found: $TOOLBOX_DIR/_lib/rules.sh"
# shellcheck source=/dev/null
source "$TOOLBOX_DIR/_lib/rules.sh"

# optional libs (if you have them)
[[ -f "$LIB_DIR/std.sh" ]] || die "std.sh not found: $LIB_DIR/std.sh"
[[ -f "$LIB_DIR/log.sh" ]] || die "log.sh not found: $LIB_DIR/log.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/std.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/log.sh"

SCRIPT_TITLE="${SCRIPT_TITLE:-My Script}"
RUN_TS="${RUN_TS:-$(std_now_ts)}"

# defaults (IMPORTANT: always quote the default value)
std_default DRY_RUN "false"

# ---------- Print header ----------
std_print_header
std_kv "RUN_ID"   "$RUN_TS"
std_kv "DRY_RUN"  "$DRY_RUN"
[[ -n "${MODE-}"     ]] && std_kv "Mode"     "$MODE"
[[ -n "${SEGMENTS-}" ]] && std_kv "Segments" "$SEGMENTS"
echo

# ---------- Your code here ----------
# ... your script logic ...
# ---------- Print footer ----------
# after you computed OUT_FILE / WORKDIR etc.
[[ -n "${OUT_FILE-}" ]] && std_kv "Output"  "$OUT_FILE"
[[ -n "${WORKDIR-}"  ]] && std_kv "Workdir" "$WORKDIR"
echo
std_footer_summary "Done! ($RUN_TS)"
