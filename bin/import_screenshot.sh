#!/usr/bin/env bash
set -Eeuo pipefail

die(){ echo "[ERROR] $*" >&2; exit 1; }
warn(){ echo "[WARN]  $*" >&2; }

need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "command not found: $1"; }
need_cmd sips

# ---------- Config ----------
SCREEN_DIR="${SCREEN_DIR:-$HOME/Desktop/截屏}"

REPO_DIR="${REPO_DIR:-$HOME/toolbox/changelog}"
ASSETS_DIR="${ASSETS_DIR:-$REPO_DIR/_assets}"          # tracked
RAW_DIR="${RAW_DIR:-$REPO_DIR/_assets_raw}"            # untracked (gitignored)
SLUG_CACHE_FILE="${SLUG_CACHE_FILE:-$REPO_DIR/.last_slug}"


# naming
SLUG="${SLUG:-}"          # e.g. N1-01_ping-only ; if empty -> prompt
TS_MODE="${TS_MODE:-now}" # now | mtime (use file modified time)
MAX_PX="${MAX_PX:-2000}"  # downscale max px

# clipboard
COPY_MD="${COPY_MD:-1}"   # 1 = pbcopy markdown, 0 = no

mkdir -p "$ASSETS_DIR" "$RAW_DIR"

# ---------- Helpers ----------
prompt_slug() {
  local last=""
  if [[ -f "$SLUG_CACHE_FILE" ]]; then
    last="$(cat "$SLUG_CACHE_FILE" 2>/dev/null || true)"
  fi

  local out="${SLUG:-}"
  if [[ -z "$out" ]]; then
    printf "slug (Enter=%s) > " "${last:-misc}" >/dev/tty
    IFS= read -r out </dev/tty || true
    [[ -z "$out" ]] && out="${last:-misc}"
  fi

  out="${out// /-}"
  out="${out//[^A-Za-z0-9._-]/-}"
  [[ -n "$out" ]] || out="misc"

  printf "%s" "$out" >"$SLUG_CACHE_FILE"
  printf "%s" "$out"
}


# macOS: stat -f %m gives mtime epoch seconds
ts_from_now(){ date +"%Y%m%d_%H%M%S"; }
ts_from_mtime(){
  local f="$1"
  local epoch
  epoch="$(stat -f '%m' "$f")"
  date -r "$epoch" +"%Y%m%d_%H%M%S"
}

# core: list files sorted by modified time (old -> new, newest at bottom)
pick_files() {
  local files=()
  if command -v fzf >/dev/null 2>&1; then
    mapfile -t files < <(
      find "$SCREEN_DIR" -maxdepth 1 -type f \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" \) -print0 \
      | xargs -0 -I{} stat -f '%m %N' "{}" \
      | sort -rn \
      | cut -d' ' -f2- \
      | fzf -m --prompt="Select screenshot(s): " || true
    )
  else
    local latest
    latest="$(ls -t "$SCREEN_DIR"/* 2>/dev/null | head -n 1 || true)"
    [[ -n "${latest:-}" ]] || die "no screenshots found in: $SCREEN_DIR"
    files=("$latest")
  fi

  ((${#files[@]} > 0)) || die "no file selected"
  printf "%s\n" "${files[@]}"
}

make_compact_png() {
  local src="$1"
  local out="$2"
  # Downscale to MAX_PX, keep png
  sips -Z "$MAX_PX" -s format png "$src" --out "$out" >/dev/null
}

main() {
  [[ -d "$SCREEN_DIR" ]] || die "SCREEN_DIR not found: $SCREEN_DIR"
  [[ -d "$REPO_DIR" ]] || die "REPO_DIR not found: $REPO_DIR"

  local slug; slug="$(prompt_slug)"

  mapfile -t picked < <(pick_files)

  local md=""
  local n=0

  for src in "${picked[@]}"; do
    [[ -f "$src" ]] || { warn "skip missing: $src"; continue; }
    n=$((n+1))

    local ts
    if [[ "$TS_MODE" == "mtime" ]]; then
      ts="$(ts_from_mtime "$src")"
    else
      ts="$(ts_from_now)"
    fi

    local seq=""
    if ((${#picked[@]} > 1)); then
      seq="$(printf "-%02d" "$n")"
    fi

    # always output png to assets (web-friendly)
    local base="${ts}_${slug}${seq}"
    local raw_path="$RAW_DIR/${base}.png"
    local compact_path="$ASSETS_DIR/${base}.png"

    # raw: keep original bytes? (png/jpg) -> to simplify we normalize into png raw too
    # If you want "raw keep original extension", tell me; we can do that.
    make_compact_png "$src" "$raw_path"

    # compact (can be same processing; but keep separate in case you later change raw policy)
    make_compact_png "$raw_path" "$compact_path"

    md+="![](assets/${base}.png)\n"
  done

  echo
  echo "[OK] Imported: $n file(s)"
  echo "Raw:    $RAW_DIR (gitignored)"
  echo "Assets: $ASSETS_DIR (tracked)"
  echo
  echo "Markdown:"
  printf "%b" "$md"

  if [[ "$COPY_MD" == "1" ]] && command -v pbcopy >/dev/null 2>&1; then
    printf "%b" "$md" | pbcopy
    echo
    echo "[OK] Markdown copied to clipboard."
  fi
}

main "$@"
