#!/usr/bin/env bash
set -Eeuo pipefail
die(){ echo "[ERROR] $*" >&2; exit 1; }

TOOLBOX_DIR="${TOOLBOX_DIR:-$HOME/toolbox}"
DOC="${DOC:-$TOOLBOX_DIR/docs/TROUBLESHOOTING.md}"

command -v fzf >/dev/null 2>&1 || true  # optional
[[ -f "$DOC" ]] || die "Troubleshooting doc not found: $DOC"

read_tty() {
  local prompt="$1"
  local out=""
  printf "%s" "$prompt" >/dev/tty
  IFS= read -r out </dev/tty || true
  printf "%s" "$out"
}

get_next_t() {
  local last
  last="$(grep -Eo '^##[[:space:]]+T[0-9]+' "$DOC" \
    | grep -Eo 'T[0-9]+' | sed 's/T//' | sort -n | tail -n1 || true)"
  if [[ -z "${last:-}" ]]; then
    echo "1"
  else
    echo $(( last + 1 ))
  fi
}

sanitize_one_line() {
  local s="$1"
  s="${s//$'\r'/}"
  s="$(printf "%s" "$s" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  printf "%s" "$s"
}

main() {
  local tnum title tags symptom
  tnum="$(get_next_t)"

  title="$(read_tty "Title (one line): ")"
  title="$(sanitize_one_line "$title")"
  [[ -n "$title" ]] || die "title is required"

  tags="$(read_tty "Tags (space-separated, optional): ")"
  tags="$(sanitize_one_line "$tags")"

  symptom="$(read_tty "Symptom (one line, user language): ")"
  symptom="$(sanitize_one_line "$symptom")"
  [[ -n "$symptom" ]] || die "symptom is required"

  local now
  now="$(date '+%Y-%m-%d %H:%M')"

  local tag_line=""
  if [[ -n "$tags" ]]; then
    tag_line="#${tags// / #}"
  fi

  local block
  block=$(
    cat <<EOF

## T${tnum} | ${title}
${tag_line}

**Created**: ${now}

**A. 触发（Friction）**
- ${symptom}

**B. 证据（Evidence）**
\`\`\`bash
# paste commands + outputs
\`\`\`

**C. 判定（Diagnosis）**
- 

**D. 修复（Fix）**
\`\`\`bash
# paste fix commands
\`\`\`

**E. 回归测试（Verify）**
\`\`\`bash
# how to confirm it's resolved
\`\`\`

**F. 预防（Prevention）**
- 
EOF
  )

  # Append (hard fail if it doesn't write)
  printf "%s\n" "$block" >> "$DOC" || die "failed to append to: $DOC"

  echo "[OK] Added: T${tnum} -> $DOC"

  # Jump to new entry
  local line
  line="$(grep -nE "^##[[:space:]]+T${tnum}[[:space:]]*\\|" "$DOC" | tail -n1 | cut -d: -f1 || true)"

  if command -v code >/dev/null 2>&1; then
    if [[ -n "${line:-}" ]]; then
      code -g "$DOC:$line"
    else
      code -g "$DOC"
    fi
    exit 0
  fi

  if [[ -d "/Applications/Visual Studio Code.app" ]]; then
    open -a "Visual Studio Code" "$DOC"
    exit 0
  fi

  open "$DOC"
}

main "$@"
