#!/usr/bin/env bash
# no-hardcoded-paths.sh — fail if maintainer-specific paths leak into shipped code.
#
# The forge codebase ships into other developers' machines. Hardcoded references
# to `__DEV`, `/Users/<maintainer>`, or Schibsted brand identifiers would
# silently break installs (the PR #6 sweep on 2026-05-20 cleaned all known
# occurrences). This linter guards against re-introduction.
#
# Scans `adapters/`, `core/`, `install.sh` for FORBIDDEN patterns and reports
# hits that aren't whitelisted in `scripts/lint/no-hardcoded-paths.allow`.
#
# Intended invocation surfaces:
#   ./scripts/lint/no-hardcoded-paths.sh           # CLI (manual run, CI later)
#   .git/hooks/pre-commit -> scripts/git-hooks/pre-commit  # local dev guard
#
# Exit codes:
#   0 = pass (no forbidden hits, or all hits whitelisted)
#   1 = fail (forbidden hits not in allowlist)
#   2 = usage error

set -uo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n 's/^# \{0,1\}//p' "$0" | sed -n '1,/^$/p'
  exit 0
fi

# Locate repo root from script position. The script must live at
# <repo>/scripts/lint/no-hardcoded-paths.sh.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$REPO_ROOT" || { echo "[lint-no-hardcoded-paths] repo root not found at $REPO_ROOT" >&2; exit 2; }

# Forbidden patterns:
#   __DEV               — maintainer's vault root directory name
#   /Users/[^/]+        — any absolute macOS home path (catches /Users/shiva.bernhard@m10s.io)
#   SCHIBSTED|FINN|TORI — Schibsted brand identifiers that have appeared historically
#   |BLOCKET|DBA        — additional Schibsted brand identifiers
FORBIDDEN='__DEV|/Users/[^/]+|SCHIBSTED|FINN|TORI|BLOCKET|DBA'

# Scope: only files under these paths. Restrict file extensions to those that
# actually ship to user runtime (skip e.g. .git, .obsidian, vendored deps).
SCOPE=(adapters/ core/ install.sh)
EXTENSIONS=(--include='*.sh' --include='*.py' --include='*.md' --include='*.kts' --include='*.json' --include='*.conf')

ALLOWLIST_FILE="scripts/lint/no-hardcoded-paths.allow"

# Scan. Each hit is a <file>:<line>:<content> line from grep.
ALL_HITS=$(grep -rnE "$FORBIDDEN" "${SCOPE[@]}" "${EXTENSIONS[@]}" 2>/dev/null || true)

if [ -z "$ALL_HITS" ]; then
  echo "[lint-no-hardcoded-paths] PASS — no forbidden patterns found in scope"
  exit 0
fi

# Filter out allowlisted entries. The allowlist uses <file>:<line> prefixes;
# match by prefix against each hit's "file:line:" portion.
if [ -f "$ALLOWLIST_FILE" ]; then
  # Build a grep -F pattern file of <file>:<line>: prefixes from the allowlist.
  # Lines starting with # or blank are comments/skipped.
  ALLOW_PREFIXES=$(grep -vE '^\s*(#|$)' "$ALLOWLIST_FILE" 2>/dev/null | sed 's/$/:/')
else
  ALLOW_PREFIXES=""
fi

if [ -n "$ALLOW_PREFIXES" ]; then
  UNAPPROVED=$(printf '%s\n' "$ALL_HITS" | grep -vFf <(printf '%s\n' "$ALLOW_PREFIXES") || true)
else
  UNAPPROVED="$ALL_HITS"
fi

if [ -z "$UNAPPROVED" ]; then
  echo "[lint-no-hardcoded-paths] PASS — all hits are in the allowlist"
  exit 0
fi

# Fail with the unapproved hits.
echo "[lint-no-hardcoded-paths] FAIL — hardcoded maintainer paths found in shipped code:" >&2
echo "" >&2
printf '%s\n' "$UNAPPROVED" >&2
echo "" >&2
echo "If a hit above is intentional (e.g. teaching example, prose mention)," >&2
echo "add the matching <file>:<line> to: $ALLOWLIST_FILE" >&2
echo "" >&2
echo "(Forbidden patterns: $FORBIDDEN)" >&2
exit 1
