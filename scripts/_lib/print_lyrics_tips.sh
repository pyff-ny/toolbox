print_lyrics_tips() {
  cat <<EOF

💡 Tips:
  - hybrid mode with different interval:
      $0 "$IN" "$LANG_OUT" hybrid 8

  - fixed mode for consistent segments:
      $0 "$IN" "$LANG_OUT" fixed 10

  - Adjust SILENCE_THRESHOLD (-25dB ~ -40dB) for auto mode
EOF
}
