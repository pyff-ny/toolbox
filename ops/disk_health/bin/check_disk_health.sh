#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$BASE_DIR/scripts/check_disk_health.sh"

if [[ ! -e "$TARGET" ]]; then
  echo "[ERROR] target not found: $TARGET" >&2
  exit 1
fi

exec bash "$TARGET" "$@"
