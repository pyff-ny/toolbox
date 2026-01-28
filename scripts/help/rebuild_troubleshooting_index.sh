#!/usr/bin/env bash
set -Eeuo pipefail
die(){ echo "[ERROR] $*" >&2; exit 1; }

TOOLBOX_DIR="${TOOLBOX_DIR:-$HOME/toolbox}"
SRC="${SRC:-$TOOLBOX_DIR/docs/TROUBLESHOOTING.md}"
OUT="${OUT:-$TOOLBOX_DIR/docs/TROUBLESHOOTING_INDEX.md}"

[[ -f "$SRC" ]] || die "Source not found: $SRC"

SYSTEM_TAGS='macos bsd diskutil uchg schg fs permission shortcut vm'
TOOLS_TAGS='rsync fzf zsh wrapper git vscode'
INTERACT_TAGS='read_tty ctrlc trap input ui'
STRUCT_TAGS='path naming whitelist flatten boundary'

now="$(date '+%Y-%m-%d %H:%M')"

awk -v now="$now" \
    -v system="$SYSTEM_TAGS" -v tools="$TOOLS_TAGS" -v interact="$INTERACT_TAGS" -v struct="$STRUCT_TAGS" '
function has_any(tagline, words,   n,i,w) {
  n=split(words, a, " ")
  for(i=1;i<=n;i++){
    w=a[i]
    if (w=="") continue
    if (tagline ~ ("#" w "([^A-Za-z0-9_]|$)")) return 1
  }
  return 0
}
function emit(section, line){
  if (line=="") return
  out[section] = out[section] "- " line "\n"
}
BEGIN{
  cur=""
  tags=""
  sec="Misc"
}
# 标题行：## Tn | title
/^##[[:space:]]+T[0-9]+[[:space:]]*\|/{
  # flush previous
  if (cur!="") emit(sec, cur)

  cur=$0
  sub(/^##[[:space:]]+/, "", cur)   # "T14 | title"
  tags=""
  sec="Misc"
  next
}
# tag 行：以 # 开头的一整行
/^#[^#]/{
  if (cur!="") {
    tags=$0
    if (has_any(tags, system)) sec="System"
    else if (has_any(tags, tools)) sec="Tools"
    else if (has_any(tags, interact)) sec="Interaction"
    else if (has_any(tags, struct)) sec="Structure"
    else sec="Misc"
  }
  next
}
END{
  if (cur!="") emit(sec, cur)

  print "# Troubleshooting Index (read-only)"
  print ""
  print "- Source: `docs/TROUBLESHOOTING.md`"
  print "- Generated: " now
  print ""
  print "## System"
  print out["System"]
  print "## Tools"
  print out["Tools"]
  print "## Interaction"
  print out["Interaction"]
  print "## Structure"
  print out["Structure"]
  print "## Misc"
  print out["Misc"]
}
' "$SRC" > "$OUT"

echo "[OK] Rebuilt index -> $OUT"
