#!/usr/bin/env bash
set -Eeuo pipefail
die(){ echo "[ERROR] $*" >&2; exit 1; }

TOOLBOX_DIR="${TOOLBOX_DIR:-$HOME/toolbox}"
DOC="${DOC:-$TOOLBOX_DIR/docs/Troubleshooting.md}"

[[ -f "$DOC" ]] || die "Troubleshooting doc not found: $DOC"

# 1) Prefer VS Code CLI if available
if command -v code >/dev/null 2>&1; then
  code -g "$DOC"
  exit 0
fi

# 2) Fallback: open with VS Code app (macOS)
if [[ -d "/Applications/Visual Studio Code.app" ]]; then
  open -a "Visual Studio Code" "$DOC"
  exit 0
fi

# 3) If user set EDITOR_CMD, try it
EDITOR_CMD="${EDITOR_CMD:-}"
if [[ -n "$EDITOR_CMD" ]] && command -v "$EDITOR_CMD" >/dev/null 2>&1; then
  "$EDITOR_CMD" "$DOC"
  exit 0
fi

# 4) Final fallback: view-only
command -v less >/dev/null 2>&1 || die "VS Code not found and less not available."
less "$DOC"
