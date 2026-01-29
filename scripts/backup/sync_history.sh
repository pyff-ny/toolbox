#cat > ~/toolbox/bin/sync_history <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# default: show last 10 records
N="${1:-10}"

TOOLBOX_DIR="${TOOLBOX_DIR:-$HOME/toolbox}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$TOOLBOX_DIR/scripts}"
# shellcheck source=/dev/null
source "$SCRIPTS_DIR/_lib/load_conf.sh"
LOG_DIR="${LOG_DIR:-$TOOLBOX_DIR/_out/Logs}"

INDEX="${INDEX:-$LOG_DIR/snapshot_index.tsv}"

if [[ ! -f "$INDEX" ]]; then
  echo "[ERROR] index not found: $INDEX"
  echo "Tip: run sync_reports --real at least once to generate it."
  exit 1
fi

echo "== Sync History (last $N) =="
echo "Index: $INDEX"
echo

tail -n "$N" "$INDEX" | column -t -s $'\t'
#EOF

#chmod +x ~/toolbox/bin/sync_history
