trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "$s"
}

normalize_drag_path() {
  local p="$1"
  p="$(trim "$p")"

  # remove surrounding quotes (Finder sometimes adds)
  p="${p%\"}"; p="${p#\"}"
  p="${p%\'}"; p="${p#\'}"

  # unescape common Terminal drag escapes: "\ " -> " "
  p="${p//\\ / }"

  # strip file:// if any
  p="${p#file://}"

  printf "%s" "$p"
}

read_audio_path_drag() {
  local pick_dir="$1"
  [[ -d "$pick_dir" ]] || die "AUDIO_PICK_DIR not found: $pick_dir"

  open "$pick_dir" >/dev/null 2>&1 || true
  echo "Audio file path (drag here): " >/dev/tty

  local raw=""
  IFS= read -r raw </dev/tty || return 1
  raw="$(normalize_drag_path "$raw")"
  [[ -n "$raw" ]] || return 1
  printf "%s" "$raw"
}

#===how to use===
AUDIO_PICK_DIR="${AUDIO_PICK_DIR:-$HOME/Music/Music}"
AUDIO_FILE="$(read_audio_path_drag "$AUDIO_PICK_DIR")" || { log_warn "cancelled"; exit 0; }
[[ -f "$AUDIO_FILE" ]] || die "audio file not found: $AUDIO_FILE"
