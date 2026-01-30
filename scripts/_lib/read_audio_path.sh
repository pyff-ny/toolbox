read_audio_path() {
  local p=""
  echo "Audio file path (drag here):"
  read -r p </dev/tty || return 1

  # trim
  p="${p#"${p%%[![:space:]]*}"}"
  p="${p%"${p##*[![:space:]]}"}"

  [[ -n "$p" ]] || return 1
  printf "%s" "$p"
}

AUDIO_FILE="${1:-}"
if [[ -z "$AUDIO_FILE" ]]; then
  if ! AUDIO_FILE="$(read_audio_path)"; then
    log_warn "User cancelled audio selection"
    exit 0
  fi
fi
