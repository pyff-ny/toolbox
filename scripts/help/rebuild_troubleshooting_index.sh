#!/usr/bin/env bash
# This script executes rules defined in tags.conf.
# Do not hardcode domain knowledge here.
#这是你给未来的自己留的路标。
# Classification rule:
# 1. Explicit tags (#macos, #tools, ...) have highest priority
# 2. If no tag present, fallback to title keyword matching
# 3. Fallback is index-only; source markdown remains unchanged

set -Eeuo pipefail
die(){ echo "[ERROR] $*" >&2; exit 1; }

TOOLBOX_DIR="${TOOLBOX_DIR:-$HOME/toolbox}"
SRC="${SRC:-$TOOLBOX_DIR/docs/TROUBLESHOOTING.md}"
OUT="${OUT:-$TOOLBOX_DIR/docs/TROUBLESHOOTING_INDEX.md}"

[[ -f "$SRC" ]] || die "Source not found: $SRC"
now="$(date '+%Y-%m-%d %H:%M')"

TAGS_CONF="${TAGS_CONF:-$TOOLBOX_DIR/_lib/tags.conf}"
[[ -f "$TAGS_CONF" ]] || die "tags.conf not found: $TAGS_CONF"

awk -v now="$now" -v conf="$TAGS_CONF" '
function classify(tagline,   s,n,i,t){
  if(tagline=="") return "Misc"
  s=tolower(tagline)
  gsub(/#/, " ", s)
  gsub(/[[:space:]]+/, " ", s)
  n=split(s, tok, " ")
  for(i=1;i<=n;i++){ t=tok[i]; if(sys[t])  return "System" }
  for(i=1;i<=n;i++){ t=tok[i]; if(tol[t])  return "Tools" }
  for(i=1;i<=n;i++){ t=tok[i]; if(ints[t]) return "Interaction" }
  for(i=1;i<=n;i++){ t=tok[i]; if(stu[t])  return "Structure" }
  return "Misc"
}

function load_conf(file,   line,section){
  section=""
  while ((getline line < file) > 0) {
    line=tolower(line)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
    if (line=="" || line ~ /^;/ || line ~ /^#/) continue
    if (line=="[system]") { section="sys"; continue }
    if (line=="[tools]") { section="tol"; continue }
    if (line=="[interaction]") { section="ints"; continue }
    if (line=="[structure]") { section="stu"; continue }
    if (section=="sys") sys[line]=1
    else if (section=="tol") tol[line]=1
    else if (section=="ints") ints[line]=1
    else if (section=="stu") stu[line]=1
  }
  close(file)
}

function emit(section, line){
  if(line=="") return
  out[section]=out[section] "- " line "\n"
}

BEGIN{
  load_conf(conf)
  cur=""; sec="Misc"; got_tag=0
}

# Heading
/^##[[:space:]]+T[0-9]+[[:space:]]*\|/{
  if(cur!="") emit(sec, cur)
  cur=$0
  sub(/^##[[:space:]]+/, "", cur)
  sec="Misc"
  got_tag=0
  next
}

# first tag line only
(cur!="") && (got_tag==0) && (index($0, "#") > 0) {
  tags = substr($0, index($0,"#"))
  if (substr(tags,1,1) == "#") {
    sec = classify(tags)
    got_tag=1
  }
  next
}

END{
  if(cur!="") emit(sec, cur)
  print "# Troubleshooting Index (read-only)\n"
  print "- Source: `docs/TROUBLESHOOTING.md`"
  print "- Generated: " now "\n"
  print "## System";      printf "%s", out["System"];      print ""
  print "## Tools";       printf "%s", out["Tools"];       print ""
  print "## Interaction"; printf "%s", out["Interaction"]; print ""
  print "## Structure";   printf "%s", out["Structure"];   print ""
  print "## Misc";        printf "%s", out["Misc"];        print ""
}
' "$SRC" > "$OUT"


echo "[OK] Rebuilt index -> $OUT"
