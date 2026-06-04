#!/usr/bin/env bash
# setup-dev.sh — one-time setup for developing on the forge repo.
#
# Currently installs git hooks (pre-commit) by symlinking versioned scripts
# into `.git/hooks/`. Re-running is safe (idempotent: replaces existing symlink,
# warns if the destination is a non-symlink file you might be using).
#
# This is intentionally separate from `install.sh`:
#   - install.sh = "I want to USE forge" (installs `~/.claude/` artifacts)
#   - setup-dev.sh = "I want to DEVELOP on forge" (sets up local dev guards)
#
# Usage:
#   ./scripts/setup-dev.sh         Install all dev tooling
#   ./scripts/setup-dev.sh --help  Show this help

set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n 's/^# \{0,1\}//p' "$0" | sed -n '1,/^$/p'
  exit 0
fi

REPO_ROOT="$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ]; then
  echo "setup-dev.sh: not inside the forge git repo" >&2
  exit 1
fi
cd "$REPO_ROOT"

echo "Installing forge dev tooling in: $REPO_ROOT"
echo ""

# Git hooks. Each entry is "<hook-name>:<source-relative-path>".
HOOKS=(
  "pre-commit:scripts/git-hooks/pre-commit"
)

for entry in "${HOOKS[@]}"; do
  HOOK_NAME="${entry%%:*}"
  SOURCE_REL="${entry#*:}"
  DEST=".git/hooks/$HOOK_NAME"

  if [ ! -f "$SOURCE_REL" ]; then
    echo "  ✗ $HOOK_NAME — source missing at $SOURCE_REL (skipped)"
    continue
  fi

  if [ -L "$DEST" ]; then
    # Existing symlink — replace it (covers re-runs after script updates).
    rm "$DEST"
    ln -s "../../$SOURCE_REL" "$DEST"
    echo "  ✓ $HOOK_NAME — symlink refreshed"
  elif [ -e "$DEST" ]; then
    # Non-symlink file already there — don't clobber. User may have customized.
    echo "  ! $HOOK_NAME — $DEST exists as a regular file (not a symlink)"
    echo "    Refusing to overwrite. To use the versioned hook, manually:"
    echo "      rm $DEST && ln -s ../../$SOURCE_REL $DEST"
  else
    ln -s "../../$SOURCE_REL" "$DEST"
    echo "  ✓ $HOOK_NAME — symlinked"
  fi
done

echo ""
echo "Done. Hooks active for git operations in this clone."
echo "To verify: try \`git commit\` (the pre-commit hook should run lint checks)."
