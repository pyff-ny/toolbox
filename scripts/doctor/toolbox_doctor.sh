#!/usr/bin/env bash
set -euo pipefail

ok(){ printf "[OK] %s\n" "$*"; }
bad(){ printf "[FAIL] %s\n" "$*"; exit 1; }
warn(){ printf "[WARN] %s\n" "$*"; }

ROOT="${TOOLBOX_ROOT:-$HOME/toolbox}"
CONF_DIR="${CONF_DIR:-$ROOT/conf}"
CFG="${CFG:-$CONF_DIR/ssh_sync.conf}"

#echo "== TOOLBOX Doctor =="
echo "Root: $ROOT"
echo "Conf: $CFG"
echo

# -------------------------
# core commands in PATH
# -------------------------
for c in toolbox_D netcheck sync_reports sync_history; do
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
[[ -d "$HOME/toolbox/_out/Logs" ]] && ok "~/Logs exists" || bad "~/Logs missing"
[[ -d "$HOME/toolbox/_out/IT-Reports" ]] && ok "Reports folder exists" || ok "Reports folder will be created on run"

# -------------------------
# ssh preflight (optional but recommended)
# -------------------------
if [[ -f "$CFG" ]]; then
  # shellcheck disable=SC1090
  source "$CFG"

  # ssh target build
  TARGET="${SSH_HOST:-}"
  if [[ -z "$TARGET" ]]; then
    warn "SSH_HOST not set in $CFG, skip SSH preflight"
  else
    if [[ -n "${SSH_USER:-}" && "$TARGET" != *"@"* ]]; then
      TARGET="${SSH_USER}@${TARGET}"
    fi

    if ssh -o BatchMode=yes -o ConnectTimeout=3 "$TARGET" "echo ok" >/dev/null 2>&1; then
      ok "SSH reachable: $TARGET"
    else
      warn "SSH preflight failed: $TARGET (maybe first-time auth needed)"
      warn "Try manually once: ssh $TARGET"
    fi
  fi
else
  warn "Config missing, skip SSH preflight: $CFG"
fi

echo
echo "DONE"
