get_audio_file() {
  local default_dir="${1:-$HOME/Music/Music}"
  local p="${2:-}"   # incoming value, may be empty

  # 1) already provided
  if [[ -n "$p" ]]; then
    [[ -f "$p" ]] || die "Audio file not found: $p"
    printf "%s" "$p"
    return 0
  fi

  # 2) prompt (drag here); empty input => choose file dialog (optional)
  echo "Audio file path (drag here, Enter to choose):"
  if IFS= read -r p </dev/tty; then
    # trim
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
  else
    return 1
  fi

  if [[ -z "$p" ]]; then
    # optional chooser
    p="$(osascript <<EOF
set defaultFolder to POSIX file "$default_dir"
set f to choose file with prompt "Choose an audio file" default location defaultFolder
POSIX path of f
EOF
)" || return 1
  fi

  [[ -f "$p" ]] || die "Audio file not found: $p"
  printf "%s" "$p"
}
