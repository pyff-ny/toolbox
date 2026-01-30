#!/usr/bin/env bash
set -Eeuo pipefail

TOOLBOX_DIR="${TOOLBOX_DIR:-$HOME/toolbox}"
exec "$TOOLBOX_DIR/scripts/backup/sync_reports.sh" --real "$@"
