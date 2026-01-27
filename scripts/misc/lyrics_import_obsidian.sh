#!/usr/bin/env bash
set -euo pipefail

# -------- Config --------
VAULT_ROOT="${VAULT_ROOT:-$HOME/Obsidian/macOS/40_MediaNotes}"
LIB_ROOT="$VAULT_ROOT/Lyrics"

die() { echo "ERROR: $*" >&2; exit 1; }

# -------- Args --------
# usage:
#   lyrics_import_obsidian.sh <WORKDIR> [--title "Young and Beautiful"] [--artist "Lana Del Rey"] [--lang en]
WORKDIR="${1:-}"
[[ -n "$WORKDIR" ]] || die "Missing WORKDIR. Example: lyrics_import_obsidian.sh /path/to/workdir --title '...' --artist '...'"
[[ -d "$WORKDIR" ]] || die "WORKDIR not found: $WORKDIR"

shift || true

TITLE=""
ARTIST=""
LANG="en"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)  TITLE="${2:-}"; shift 2;;
    --artist) ARTIST="${2:-}"; shift 2;;
    --lang)   LANG="${2:-en}"; shift 2;;
    *) die "Unknown arg: $1";;
  esac
done

# -------- Helpers --------
read_meta() {
  local key="$1"
  local meta="$WORKDIR/meta.txt"
  [[ -f "$meta" ]] || return 1
  # format: key=value
  local val
  val="$(grep -E "^${key}=" "$meta" | head -n1 | cut -d= -f2- || true)"
  [[ -n "$val" ]] || return 1
  printf "%s" "$val"
}

sanitize_path_component() {
  # Keep it simple: remove slashes, trim spaces
  local s="$1"
  s="${s//\//-}"
  s="$(echo "$s" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  printf "%s" "$s"
}

# -------- Derive fields --------
# Prefer CLI args, then meta.txt, then fallback to WORKDIR basename pattern Title-Artist
if [[ -z "$TITLE" ]]; then
  TITLE="$(read_meta "title" || true)"
fi
if [[ -z "$ARTIST" ]]; then
  ARTIST="$(read_meta "artist" || true)"
fi

BASENAME="$(basename "$WORKDIR")"

if [[ -z "$TITLE" || -z "$ARTIST" ]]; then
  # Try parse from "<Title-Artist>" pattern (last "-" split is risky; we do a conservative split on first "-")
  if [[ "$BASENAME" == *"-"* ]]; then
    local_title="${BASENAME%%-*}"
    local_artist="${BASENAME#*-}"
    [[ -z "$TITLE" ]] && TITLE="$local_title"
    [[ -z "$ARTIST" ]] && ARTIST="$local_artist"
  fi
fi

[[ -n "$TITLE" ]] || die "Title not provided and not found in meta.txt or WORKDIR name."
[[ -n "$ARTIST" ]] || die "Artist not provided and not found in meta.txt or WORKDIR name."

TITLE="$(sanitize_path_component "$TITLE")"
ARTIST="$(sanitize_path_component "$ARTIST")"
NOTE_NAME="${TITLE}-${ARTIST}"

# Optional meta fields
SOURCE="$(read_meta "source" || true)"
MODE_USED="$(read_meta "mode_used" || read_meta "mode" || true)"
INTERVAL="$(read_meta "interval" || true)"
MODEL="$(read_meta "model" || true)"

# -------- Target paths --------
TARGET_DIR="$LIB_ROOT/$ARTIST/$NOTE_NAME"
mkdir -p "$TARGET_DIR" || die "Failed to create target dir: $TARGET_DIR"
# -------- Ensure meta.txt (auto-generate if missing) --------
META_SRC="$WORKDIR/meta.txt"
META_DST="$TARGET_DIR/meta.txt"

if [[ -f "$META_SRC" ]]; then
  cp -f "$META_SRC" "$META_DST"
else
  {
    echo "title=$TITLE"
    echo "artist=$ARTIST"
    echo "lang=$LANG"
    echo "source=${SOURCE:-$WORKDIR}"
    echo "mode_used=${MODE_USED:-}"
    echo "interval=${INTERVAL:-}"
    echo "model=${MODEL:-}"
    echo "imported_at=$(date -Is)"
  } > "$META_DST"
fi

# -------- Copy artifacts --------
# Copy common outputs; ignore if none
shopt -s nullglob
for f in "$WORKDIR"/*.srt "$WORKDIR"/*.srt.txt "$WORKDIR"/*.txt "$WORKDIR"/*.tsv; do
  cp -f "$f" "$TARGET_DIR/" || die "Failed to copy: $f"
done
shopt -u nullglob

# Determine best embeds (prefer cleaned text if exists)
EMBED_TXT=""
EMBED_SRT=""

# pick first matching
for f in "$TARGET_DIR"/*.txt; do
  # avoid meta.txt
  [[ "$(basename "$f")" == "meta.txt" ]] && continue
  EMBED_TXT="$(basename "$f")"
  break
done
for f in "$TARGET_DIR"/*.srt "$TARGET_DIR"/*.srt.txt; do
  EMBED_SRT="$(basename "$f")"
  break
done

# -------- Write note --------
NOTE_MD="$TARGET_DIR/$NOTE_NAME.md"

# YAML-safe date
CREATED="$(date +%F)"

cat > "$NOTE_MD" <<EOF
---
type: lyrics
title: "$TITLE"
artist: "$ARTIST"
lang: "$LANG"
created: "$CREATED"
note: "$NOTE_NAME"
source: "${SOURCE:-}"
mode_used: "${MODE_USED:-}"
interval: "${INTERVAL:-}"
model: "${MODEL:-}"
tags: [lyrics, $LANG]
---

## Lyrics (clean)
$( [[ -n "$EMBED_TXT" ]] && echo "![[${EMBED_TXT}]]" || echo "_No .txt found in folder._" )

## Lyrics (timed)
$( [[ -n "$EMBED_SRT" ]] && echo "![[${EMBED_SRT}]]" || echo "_No .srt/.srt.txt found in folder._" )

## Highlights (for speaking/writing)
- 

## Vocabulary / Phrases
- 

## Interpretation / Theme
- 

## My takeaways (1–3 lines)
- 
EOF

echo "Imported to: $NOTE_MD"
