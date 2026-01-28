#!/usr/bin/env bash
set -Eeuo pipefail
die(){ echo "[ERROR] $*" >&2; exit 1; }

TOOLBOX_DIR="${TOOLBOX_DIR:-$HOME/toolbox}"
DOC="${DOC:-$TOOLBOX_DIR/docs/TROUBLESHOOTING_INDEX.md}"

[[ -f "$DOC" ]] || die "Index not found: $DOC (run rebuild_troubleshooting_index first)"

if command -v code >/dev/null 2>&1; then
  code -g "$DOC"
  exit 0
fi

if [[ -d "/Applications/Visual Studio Code.app" ]]; then
  open -a "Visual Studio Code" "$DOC"
  exit 0
fi

open "$DOC"
