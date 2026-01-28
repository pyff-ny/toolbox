#!/usr/bin/env bash
set -Eeuo pipefail
die(){ echo "[ERROR] $*" >&2; exit 1; }

TOOLBOX_DIR="${TOOLBOX_DIR:-$HOME/toolbox}"
DOC="${DOC:-$TOOLBOX_DIR/docs/TROUBLESHOOTING.md}"

command -v fzf >/dev/null 2>&1 || die "fzf not found"
[[ -f "$DOC" ]] || die "Troubleshooting doc not found: $DOC"

# Build list: "TITLE<TAB>LINE"
mapfile -t items < <(
  awk '
    /^##[[:space:]]+T[0-9]+[[:space:]]*\|/ {
      line=NR
      sub(/^##[[:space:]]+/, "", $0)
      printf "%s\t%d\n", $0, line
    }
  ' "$DOC"
)

((${#items[@]} > 0)) || die "No entries found (expected headings like: ## T1 | ...)"

# Show only TITLE in fzf, keep LINE as hidden tab field
sel="$(
  printf "%s\n" "${items[@]}" \
  | fzf --with-nth=1 --delimiter=$'\t' --prompt="Troubleshooting > " \
        --height=12 --border --no-info
)" || exit 0

title="${sel%%$'\t'*}"
line="${sel##*$'\t'}"
[[ -n "${line:-}" ]] || die "Failed to parse line number for: $title"

# Prefer VS Code jump-to-line
if command -v code >/dev/null 2>&1; then
  code -g "$DOC:$line"
  exit 0
fi

# Fallback: open with VS Code app (no line jump)
if [[ -d "/Applications/Visual Studio Code.app" ]]; then
  open -a "Visual Studio Code" "$DOC"
  echo "[INFO] Tip: Install VS Code 'code' command to jump to line"
  exit 0
fi

# Final fallback: open default editor/viewer
open "$DOC"
echo "[INFO] Tip: Use Cmd+F to search: $title"
