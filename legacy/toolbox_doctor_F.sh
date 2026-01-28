#!/usr/bin/env bash
set -euo pipefail

ok(){ printf "[OK] %s\n" "$*"; }
bad(){ printf "[FAIL] %s\n" "$*"; exit 1; }
warn(){ printf "[WARN] %s\n" "$*"; }

ROOT="${TOOLBOX_ROOT:-$HOME/toolbox}"
CONF_DIR="${CONF_DIR:-$ROOT/conf}"
#CFG="${CFG:-$CONF_DIR/ssh_sync.conf}"

#echo "== TOOLBOX Doctor =="
echo "Root: $ROOT"
#echo "Conf: $CFG"
echo

# -------------------------
# core commands in PATH
# -------------------------
for c in toolbox_F netcheck; do
  command -v "$c" >/dev/null 2>&1 && ok "cmd: $c" || bad "missing cmd: $c"
done

# -------------------------
# check broken symlinks
# -------------------------
for f in "$HOME/toolbox/bin/"*; do
  if [[ -L "$f" && ! -e "$f" ]]; then
    warn "broken symlink: $f"
  fi
done

# -------------------------
# key folders
# -------------------------
[[ -d "$HOME/toolbox" ]] && ok "~/toolbox exists" || bad "~/toolbox missing"
[[ -d "$HOME/toolbox/Logs" ]] && ok "~/Logs exists" || bad "~/Logs missing"
[[ -d "$HOME/toolbox/IT-Reports" ]] && ok "Reports folder exists" || ok "Reports folder will be created on run"



echo
echo "DONE"
