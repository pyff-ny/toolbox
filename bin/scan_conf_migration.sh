#!/usr/bin/env bash
# scan_conf_migration.sh - audit scripts for legacy config patterns (no eval)
set -Eeuo pipefail

ROOT="${1:-$HOME/toolbox}"

SCAN_DIRS=(
  "$ROOT/scripts"
  "$ROOT/bin"
  "$ROOT/_lib"
)

# include file globs
INCLUDE_GLOBS=(
  "*.sh"
  "*.bash"
)

# "legacy / mixed" indicators
PATTERNS=(
  'ENV_FILE'
  'env_file'
  'CONF_PATH'
  'CONF_DIR'
  'source[[:space:]].*/conf/'
  'source[[:space:]].*conf/.*\.env'
  'source[[:space:]].*\.env'
  '(\.|source)[[:space:]].*conf.*\.env'
  'export[[:space:]]+ENV_FILE'
  'load_conf\.sh'
  'scripts/_lib/load_conf\.sh'
  '_lib/load_conf\.sh'
)

GOOD_PATTERNS=(
  'load_module_conf[[:space:]]+"'
  'scripts/_lib/load_conf\.sh'
  'TOOLBOX_CONF_USED'
)

say(){ printf "%s\n" "$*" >&2; }
die(){ say "[ERROR] $*"; exit 1; }

[[ -d "$ROOT" ]] || die "ROOT not found: $ROOT"

say "[INFO] ROOT=$ROOT"
say "[INFO] Scanning dirs:"
for d in "${SCAN_DIRS[@]}"; do
  say "  - $d"
done
say

# Build find args for name globs: ( -name "*.sh" -o -name "*.bash" )
find_name_args=()
find_name_args+=( "(" )
for i in "${!INCLUDE_GLOBS[@]}"; do
  g="${INCLUDE_GLOBS[$i]}"
  if (( i > 0 )); then
    find_name_args+=( -o )
  fi
  find_name_args+=( -name "$g" )
done
find_name_args+=( ")" )

# Collect files
FILES=()
while IFS= read -r f; do
  [[ -n "$f" ]] && FILES+=("$f")
done < <(
  for d in "${SCAN_DIRS[@]}"; do
    [[ -d "$d" ]] || continue
    find "$d" -type f \
      "${find_name_args[@]}" \
      ! -path "*/.git/*" \
      ! -path "*/node_modules/*" \
      ! -path "*/.venv/*" \
      ! -path "*/venv/*" \
      ! -path "*/_out/*" \
      -print
  done | sort -u
)

if (( ${#FILES[@]} == 0 )); then
  say "[WARN] No files found to scan."
  exit 0
fi

hits_total=0
files_hit=0

printf "=== Toolbox Config Migration Audit ===\n"
printf "ROOT: %s\n" "$ROOT"
printf "Timestamp: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf '%s\n' "--------------------------------------"
printf '\n'

for f in "${FILES[@]}"; do
  # Only scan text-ish files
  if ! file "$f" | grep -qiE 'text|shell script'; then
    continue
  fi

  matched_lines=""
  for p in "${PATTERNS[@]}"; do
    out="$(grep -nE "$p" "$f" 2>/dev/null || true)"
    [[ -n "$out" ]] && matched_lines+="$out"$'\n'
  done

  [[ -n "$matched_lines" ]] || continue

  good=0
  for gp in "${GOOD_PATTERNS[@]}"; do
    if grep -qE "$gp" "$f" 2>/dev/null; then
      good=1
      break
    fi
  done

  status="LEGACY"
  (( good )) && status="MIXED"

  files_hit=$((files_hit + 1))
  lines_count="$(printf "%s" "$matched_lines" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  hits_total=$((hits_total + lines_count))

  printf "[%s] %s\n" "$status" "${f#$ROOT/}"
  printf "  hits: %s\n" "$lines_count"
  printf "%s" "$matched_lines" | sed 's/^/  /'
  printf "\n"
done

printf '%s\n' "--------------------------------------"
printf '\n'

printf "Files flagged: %d\n" "$files_hit"
printf "Total hits:    %d\n" "$hits_total"
printf "\n"

cat <<'EOF'
=== Migration TODO (per flagged file) ===
1) Remove legacy config discovery:
   - ENV_FILE / env_file / CONF_PATH hand-built paths
   - direct "source conf/*.env"
2) Add loader skeleton:
   source "$TOOLBOX_DIR/scripts/_lib/load_conf.sh"
   load_module_conf "<module>" <required_vars...> || exit $?
   CONF_PATH="${TOOLBOX_CONF_USED:-}"
3) Ensure conf/<module>.env.example exists (tracked), ops/<module>.env exists (ignored)
EOF
