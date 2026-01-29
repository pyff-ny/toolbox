#!/usr/bin/env bash
set -Eeuo pipefail

die(){ echo "[ERROR] $*" >&2; exit 1; }

REPO_DIR="${REPO_DIR:-$HOME/toolbox/changelog}"
ASSETS_DIR="${ASSETS_DIR:-$REPO_DIR/_assets}"
RAW_DIR="${RAW_DIR:-$REPO_DIR/_assets_raw}"

# thresholds (bytes)
WARN_FILE_BYTES="${WARN_FILE_BYTES:-800000}"     # 800KB
WARN_TOTAL_BYTES="${WARN_TOTAL_BYTES:-50000000}" # 50MB
TOP_N="${TOP_N:-20}"

human_bytes() {
  local b="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY' "$b"
import sys
b=float(sys.argv[1])
units=["B","KB","MB","GB","TB"]
i=0
while b>=1024 and i<len(units)-1:
    b/=1024; i+=1
print(f"{b:.2f} {units[i]}")
PY
  else
    echo "${b} B"
  fi
}

sum_bytes_find() {
  local dir="$1"
  [[ -d "$dir" ]] || { echo 0; return; }
  find "$dir" -type f -print0 | xargs -0 stat -f '%z' 2>/dev/null | awk '{s+=$1} END{print s+0}'
}

top_files() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  # size path (bytes + full path)
  find "$dir" -type f -print0 \
    | xargs -0 -I{} stat -f '%z %N' "{}" \
    | sort -rn \
    | head -n "$TOP_N"
}

oversize_files() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  find "$dir" -type f -print0 \
    | xargs -0 -I{} stat -f '%z %N' "{}" \
    | awk -v lim="$WARN_FILE_BYTES" '$1>lim{print}'
}

main() {
  [[ -d "$REPO_DIR" ]] || die "REPO_DIR not found: $REPO_DIR"

  echo "Repo:   $REPO_DIR"
  echo "Assets: $ASSETS_DIR"
  echo "Raw:    $RAW_DIR"
  echo

  local total_assets total_raw
  total_assets="$(sum_bytes_find "$ASSETS_DIR")"
  total_raw="$(sum_bytes_find "$RAW_DIR")"

  echo "Total assets: $(human_bytes "$total_assets")"
  echo "Total raw:    $(human_bytes "$total_raw")"

  echo
  if (( total_assets > WARN_TOTAL_BYTES )); then
    echo "[WARN] assets total exceeds threshold: $(human_bytes "$WARN_TOTAL_BYTES")"
  else
    echo "[OK]   assets total within threshold:  $(human_bytes "$WARN_TOTAL_BYTES")"
  fi

  echo
  echo "Top $TOP_N largest files in assets:"
  top_files "$ASSETS_DIR" | while IFS= read -r line; do
    # line: "bytes /path"
    bytes="${line%% *}"
    path="${line#* }"
    printf "  %10s  %s\n" "$(human_bytes "$bytes")" "$path"
  done

  echo
  echo "Oversize files (> $(human_bytes "$WARN_FILE_BYTES")) in assets:"
  if oversize_files "$ASSETS_DIR" | grep -q .; then
    oversize_files "$ASSETS_DIR" | while IFS= read -r line; do
      bytes="${line%% *}"
      path="${line#* }"
      printf "  %10s  %s\n" "$(human_bytes "$bytes")" "$path"
    done
    echo
    echo "Suggestion:"
    echo "  - Prefer moving originals to _assets_raw (gitignored)"
    echo "  - Re-import or re-compress via import_screenshot.sh"
  else
    echo "  [OK] none"
  fi
}

main "$@"
