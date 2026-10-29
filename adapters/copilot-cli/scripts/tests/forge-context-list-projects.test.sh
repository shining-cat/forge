#!/usr/bin/env bash
# Tests do_list_projects (entry project-picker list).
#
# Focus: excludes _* and *-template dirs and dirs without INDEX/checkpoint;
# groups by env; orders by recency within env; a project lacking a checkpoint
# must not abort the listing under `set -euo pipefail`.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_CONTEXT="$SCRIPT_DIR/../forge-context.sh"

PASS=0; FAIL=0

check() {
  local label="$1" cond="$2"
  if [ "$cond" = "0" ]; then echo "  ✓ $label"; PASS=$((PASS+1)); else echo "  ✗ $label"; FAIL=$((FAIL+1)); fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf 'VAULT_PATH=%s\nREPO_ROOTS=%s/repos\n' "$TMP" "$TMP" > "$TMP/forge.conf"
export FORGE_CONF_OVERRIDE="$TMP/forge.conf"

mk() { # env project checkpoint-date|"" [index-only]
  mkdir -p "$TMP/$1/$2"
  if [ -n "$3" ]; then printf -- '---\ndate: %s\n---\n' "$3" > "$TMP/$1/$2/current-checkpoint.md"; fi
  if [ "${4:-}" = "index" ]; then : > "$TMP/$1/$2/INDEX.md"; fi
}
mk PERSO old 2026-01-01
mk PERSO new 2026-09-01
mk PERSO kb-template 2026-10-01
mk PERSO _shared 2026-10-01
mk PERSO empty ""
mk PRO nockpt "" index
mk _shared whatever 2026-10-01
mk _templates whatever 2026-10-01

echo "Check 1 — list content and order"
out=$("$FORGE_CONTEXT" list-projects 2>&1); rc=$?
check "exit 0" "$rc"
names=$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')
[ "$names" = "PERSO/new PERSO/old PRO/nockpt " ]; check "grouped by env, recent first, exclusions applied (got: $names)" "$?"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
