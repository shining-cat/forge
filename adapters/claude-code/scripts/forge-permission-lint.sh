#!/usr/bin/env bash
# forge-permission-lint — anti-pattern linter for ~/.claude/settings.json
# Catches drift bugs in permissions and hooks blocks before they cause silent friction.

set -u

SETTINGS_FILE="$HOME/.claude/settings.json"

while [ $# -gt 0 ]; do
  case "$1" in
    --file) SETTINGS_FILE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--file <path>]"
      echo "  Lints ~/.claude/settings.json (or --file path) for known anti-patterns."
      echo "  Exit 0 = no critical findings. Exit 1 = at least one critical finding."
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ ! -f "$SETTINGS_FILE" ]; then
  echo "settings.json not found at: $SETTINGS_FILE" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found — install with 'brew install jq'" >&2
  exit 2
fi

CRITICAL=0
WARN=0

# Check 1: Write(...) / Edit(...) patterns where single * precedes /
# Single-* doesn't cross / in Claude Code's matcher, so the pattern silently never matches.
check1() {
  local patterns
  patterns=$(jq -r '.permissions.allow[]?, .permissions.deny[]?' "$SETTINGS_FILE" 2>/dev/null)
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    # Match Write(X) or Edit(X) where X contains a single * followed by /
    # The leading [^*] ensures we don't match ** (which would behave differently)
    if echo "$p" | grep -qE '^(Write|Edit)\([^)]*[^*]\*/[^)]*\)$'; then
      echo "[CRITICAL] check1-glob-not-crossing-slash: $p — single * doesn't cross /, pattern never matches. Use absolute path."
      CRITICAL=$((CRITICAL+1))
    fi
    # Also match if the pattern STARTS with * (no preceding char)
    if echo "$p" | grep -qE '^(Write|Edit)\(\*/[^)]*\)$'; then
      echo "[CRITICAL] check1-glob-not-crossing-slash: $p — leading single * doesn't cross /, pattern never matches. Use absolute path."
      CRITICAL=$((CRITICAL+1))
    fi
  done <<< "$patterns"
}

check1

echo ""
echo "$CRITICAL critical, $WARN warning"
[ "$CRITICAL" -eq 0 ]
