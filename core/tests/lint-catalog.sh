#!/usr/bin/env bash
# Lints core/references/script-replacement-patterns.md for structural integrity.
# Each pattern entry must have all 4 fields (When/How/Exemplar/Anti-pattern) + Scaffold.
# Exit 0 if all entries valid, 1 if any missing fields, 2 if catalog file missing.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG="$SCRIPT_DIR/../references/script-replacement-patterns.md"

if [ ! -f "$CATALOG" ]; then
  echo "[lint-catalog] FAIL: catalog file missing at $CATALOG" >&2
  exit 2
fi

REQUIRED_FIELDS=("**When to use:**" "**How it works:**" "**Exemplar:**" "**Anti-pattern:**" "**Scaffold:**")

# Extract pattern slugs: H2 headings that aren't "Adding new patterns"
patterns=$(grep -E '^## [a-z][a-z0-9-]+$' "$CATALOG" | sed 's/^## //')

if [ -z "$patterns" ]; then
  echo "[lint-catalog] FAIL: no pattern entries found (expected H2 kebab-case headings)" >&2
  exit 1
fi

fail=0
while IFS= read -r pattern; do
  # Extract section text between this H2 and the next H2 or end of file
  section=$(awk -v p="^## $pattern\$" -v stop="^## " '
    $0 ~ p { capture=1; next }
    capture && $0 ~ stop { exit }
    capture { print }
  ' "$CATALOG")

  for field in "${REQUIRED_FIELDS[@]}"; do
    if ! echo "$section" | grep -qF "$field"; then
      echo "[lint-catalog] FAIL: pattern '$pattern' missing field: $field" >&2
      fail=1
    fi
  done

  # Verify scaffold link resolves (link text inside the [...](...) on the Scaffold line)
  scaffold_link=$(echo "$section" | grep -F "**Scaffold:**" | grep -oE '\([^)]+\)' | head -1 | tr -d '()')
  if [ -n "$scaffold_link" ]; then
    # Resolve relative to catalog file
    catalog_dir="$(dirname "$CATALOG")"
    if [ ! -e "$catalog_dir/$scaffold_link" ]; then
      echo "[lint-catalog] FAIL: pattern '$pattern' scaffold link does not resolve: $scaffold_link" >&2
      fail=1
    fi
  fi
done <<< "$patterns"

if [ $fail -eq 0 ]; then
  echo "[lint-catalog] PASS: all $(echo "$patterns" | wc -l | tr -d ' ') patterns valid"
fi

exit $fail
