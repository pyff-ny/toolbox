#!/usr/bin/env bash
set -Eeuo pipefail

# -------------------------
# Config (edit if needed)
# -------------------------
#set -x # Enable debug output
TOOLBOX_DIR="${TOOLBOX_DIR:-$HOME/toolbox}"
CHANGELOG_FILE="${CHANGELOG_FILE:-$TOOLBOX_DIR/changelog/changelog.md}"


# Optional: where TOOLBOX_VERSION is defined (if you want to auto-edit it)
# If unset, script will only print new version and write changelog.
VERSION_FILES_DEFAULT=(

"$TOOLBOX_DIR/_lib/version.sh"
  
)

# Behavior toggles
INCLUDE_GIT_FILES_DEFAULT=1   # 1=append changed files list if git repo exists

usage() {
  cat <<'EOF'
Usage:
  bump_toolbox_version.sh [options] [reason text...]

Options:
  -c, --changelog <path>     Changelog file path (default: $HOME/toolbox/changelog/changelog.md)
  -f, --file <path>          A file to update TOOLBOX_VERSION=... in (repeatable)
  --no-version-files         Do not edit any files; only write changelog + print version
  --no-git-files             Do not append git changed files list
  --prepend                  Always prepend entry at top (ignore anchor)
  -h, --help                 Show help

Examples:
  bump_toolbox_version.sh "修复了 log 路径加载方式，统一到 _out/Logs"
  bump_toolbox_version.sh -f ~/toolbox/toolbox_super_compatible.sh "新增 LOG_DIR 变量"
  bump_toolbox_version.sh --no-git-files "仅改注释"
EOF
}

die(){ echo "[ERROR] $*" >&2; exit 1; }

# -------------------------
# Parse args
# -------------------------
INCLUDE_GIT_FILES="$INCLUDE_GIT_FILES_DEFAULT"
FORCE_PREPEND=0

VERSION_FILES=()
NO_VERSION_FILES=0

reason_parts=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--changelog)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      CHANGELOG_FILE="$2"; shift 2;;
    -f|--file)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      VERSION_FILES+=("$2"); shift 2;;
    --no-version-files)
      NO_VERSION_FILES=1; shift;;
    --no-git-files)
      INCLUDE_GIT_FILES=0; shift;;
    --prepend)
      FORCE_PREPEND=1; shift;;
    -h|--help)
      usage; exit 0;;
    *)
      reason_parts+=("$1"); shift;;
  esac
done

# If user didn't provide -f and not disabled, use defaults
if [[ $NO_VERSION_FILES -eq 0 && ${#VERSION_FILES[@]} -eq 0 ]]; then
  VERSION_FILES=("${VERSION_FILES_DEFAULT[@]}")
fi

# -------------------------
# Compute new version
# -------------------------
NEW_VERSION="$(date '+%Y-%m-%d.%H%M')"
# -------------------------
# Helpers
# -------------------------
open_changelog() {
  local f="${1:?missing file}"
  [[ -f "$f" ]] || return 0

  # 允许用户关掉自动打开
  [[ "${OPEN_CHANGELOG_AFTER_BUMP:-1}" == "1" ]] || return 0

  # 优先用你已有的 EDITOR_CMD（你之前是 code）
  if [[ -n "${EDITOR_CMD:-}" ]] && command -v "${EDITOR_CMD%% *}" >/dev/null 2>&1; then
    "$EDITOR_CMD" "$f" >/dev/null 2>&1 || true
    return 0
  fi

  # macOS / Linux fallback
  if command -v open >/dev/null 2>&1; then
    open "$f" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$f" >/dev/null 2>&1 || true
  fi
}

# -------------------------
# Reason input
# -------------------------
REASON=""
if [[ ${#reason_parts[@]} -gt 0 ]]; then
  REASON="${reason_parts[*]}"
else
  read -r -p "一句话原因（用于 changelog）： " REASON
fi
[[ -n "${REASON// /}" ]] || die "Reason cannot be empty."

# -------------------------
# Changelog: next number
# -------------------------
ts="$(date '+%Y-%m-%d %H:%M')"
# 然后把 "  [$ts]" 拼到条目末尾

touch "$CHANGELOG_FILE"

# Find max N from lines like: #18. ...
MAX_N="$(
  awk '
    /^[[:space:]]*#[0-9]+\./ {
      s=$0
      sub(/^[[:space:]]*#/, "", s)
      sub(/\..*/, "", s)
      n = s + 0
      if (n > max) max = n
    }
    END { print max + 0 }
  ' "$CHANGELOG_FILE"
)"

NEXT_N=$((MAX_N + 1))
[[ "$NEXT_N" -ge 1 ]] || NEXT_N=1



# -------------------------
# Optional: git changed files
# -------------------------
GIT_FILES_NOTE=""
if [[ "$INCLUDE_GIT_FILES" -eq 1 ]]; then
  if command -v git >/dev/null 2>&1 && git -C "$TOOLBOX_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # Prefer staged+unstaged names (but ignore untracked noise unless you want)
    changed="$(
      git -C "$TOOLBOX_DIR" diff --name-only
      git -C "$TOOLBOX_DIR" diff --cached --name-only
    )"
    changed="$(printf "%s\n" "$changed" | awk 'NF' | sort -u)"
    if [[ -n "$changed" ]]; then
      GIT_FILES_NOTE=" | files: $(echo "$changed" | tr '\n' ',' | sed 's/,$//')"
    fi
  fi
fi

ENTRY="#${NEXT_N}. ${REASON}${GIT_FILES_NOTE} [$ts]"

# -------------------------
# Insert changelog entry
# -------------------------
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

if [[ $FORCE_PREPEND -eq 1 ]]; then
  {
    echo "$ENTRY"
    cat "$CHANGELOG_FILE"
  } > "$tmp"

fi

mv "$tmp" "$CHANGELOG_FILE"

# -------------------------
# Update TOOLBOX_VERSION in files (optional)
# -------------------------
UPDATED_ANY=0
if [[ $NO_VERSION_FILES -eq 0 ]]; then
  for vf in "${VERSION_FILES[@]}"; do
    [[ -f "$vf" ]] || continue
    # Replace first occurrence of TOOLBOX_VERSION="..."
        if grep -qE '^[[:space:]]*TOOLBOX_VERSION=' "$vf"; then
      # Safer than sed -i on macOS: write to temp then mv
      tmp_vf="$(mktemp "${vf}.tmp.XXXXXX")"
      awk -v v="$NEW_VERSION" '
        BEGIN{done=0}
        {
          if (!done && $0 ~ /^[[:space:]]*TOOLBOX_VERSION=/) {
            print "TOOLBOX_VERSION=\"" v "\""
            done=1
            next
          }
          print
        }
      ' "$vf" > "$tmp_vf"

      if cmp -s "$vf" "$tmp_vf"; then
        rm -f "$tmp_vf"
      else
        mv -f "$tmp_vf" "$vf"
      fi

      UPDATED_ANY=1
      echo "[OK] Updated: $vf"
    fi

  done
fi

# -------------------------
# Output summary
# -------------------------
echo "[WARN] Changelog opened. Press ESC to dismiss any editor overlay before saving."
open_changelog "$CHANGELOG_FILE"

echo "[OK] NEW_VERSION=${NEW_VERSION}"
echo "[OK] Changelog updated: ${CHANGELOG_FILE}"
echo "[OK] Entry: ${ENTRY}"
if [[ $NO_VERSION_FILES -eq 1 ]]; then
  echo "[INFO] Skipped updating version files (--no-version-files)."
else
  if [[ $UPDATED_ANY -eq 1 ]]; then
    echo "[OK] Updated TOOLBOX_VERSION in version files (where found)."
  else
    echo "[WARN] No TOOLBOX_VERSION= line updated (files missing or no match)."
    echo "       Use -f <file> to point to the correct file, or rely on changelog only."
  fi
fi
