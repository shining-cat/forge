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

# Check 2: Bash(*foo*) patterns with leading *
# Leading * in Bash matchers is literal (not a wildcard), pattern never matches.
check2() {
  local patterns
  patterns=$(jq -r '.permissions.allow[]?, .permissions.deny[]?' "$SETTINGS_FILE" 2>/dev/null)
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    if echo "$p" | grep -qE '^Bash\(\*'; then
      echo "[CRITICAL] check2-bash-leading-star: $p — leading * in Bash matcher is literal, pattern never matches. Use 'prefix:*' form instead."
      CRITICAL=$((CRITICAL+1))
    fi
  done <<< "$patterns"
}

check2

# Check 3: Allow patterns masked by deny pattern with same Tool prefix and inside-content "*"
# E.g. allow Bash(rm:foo*) is silently masked by deny Bash(rm:*).
check3() {
  local denies allows
  denies=$(jq -r '.permissions.deny[]?' "$SETTINGS_FILE" 2>/dev/null)
  allows=$(jq -r '.permissions.allow[]?' "$SETTINGS_FILE" 2>/dev/null)

  # Build list of "masked prefixes" from deny patterns shaped Tool(*) or Tool(verb:*)
  local masked_prefixes=""
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    local prefix=""
    if echo "$d" | grep -qE '^[A-Za-z]+\(\*\)$'; then
      # Whole-tool deny: extract "Tool("
      prefix=$(echo "$d" | sed -E 's/^([A-Za-z]+)\(\*\)$/\1(/')
    elif echo "$d" | grep -qE '^[A-Za-z]+\([^):]+:\*\)$'; then
      # Verb-deny: extract "Tool(verb:"
      prefix=$(echo "$d" | sed -E 's/^([A-Za-z]+)\(([^:]+):\*\)$/\1(\2:/')
    fi
    if [ -n "$prefix" ]; then
      masked_prefixes="${masked_prefixes}${prefix}"$'\n'
    fi
  done <<< "$denies"

  while IFS= read -r a; do
    [ -z "$a" ] && continue
    while IFS= read -r mp; do
      [ -z "$mp" ] && continue
      case "$a" in
        "$mp"*)
          # The allow starts with a masked prefix. Skip exact-match-with-deny
          # (that's "redundant", which is also bad but a separate concern).
          # For now, flag any allow that's strictly more specific than the deny.
          local content="${a#$mp}"
          # Skip if content is just "*)" (means allow IS the deny — redundant, not masked)
          if [ "$content" != "*)" ]; then
            echo "[CRITICAL] check3-allow-masked-by-deny: $a — masked by a deny pattern with the same prefix and *. Allow is never reached."
            CRITICAL=$((CRITICAL+1))
          fi
          ;;
      esac
    done <<< "$masked_prefixes"
  done <<< "$allows"
}

check3

# Check 4: Hook commands registered twice with tilde / $HOME / absolute home-equivalent forms.
# Same (event, matcher, normalized command) registered multiple times → 2× firings.
check4() {
  local triples
  triples=$(jq -r '
    .hooks // {} | to_entries[] |
    .key as $event |
    .value[]? |
    .matcher as $matcher |
    .hooks[]? |
    select(.type == "command") |
    "\($event)\t\($matcher)\t\(.command)"
  ' "$SETTINGS_FILE" 2>/dev/null)

  # Track seen normalized keys; on collision, report the original command
  local seen_keys=""
  local seen_originals=""
  while IFS= read -r triple; do
    [ -z "$triple" ] && continue
    local event matcher cmd
    event=$(echo "$triple" | cut -f1)
    matcher=$(echo "$triple" | cut -f2)
    cmd=$(echo "$triple" | cut -f3-)

    # Normalize: ~/X → /X, $HOME/X → /X, /Users/<anyone>/X → /X
    # The leading character is whatever's left after stripping the home prefix.
    local norm="$cmd"
    norm=$(echo "$norm" | sed -E 's|^~/|/|; s|^\$HOME/|/|; s|^/Users/[^/]+/|/|')

    local key="${event}|${matcher}|${norm}"
    # Check if we've seen this normalized key before
    if echo "$seen_keys" | grep -qxF "$key"; then
      echo "[CRITICAL] check4-hook-tilde-home-dup: $event/$matcher: '$cmd' duplicates an earlier hook command (same command, different home-prefix form). Causes 2× firings."
      CRITICAL=$((CRITICAL+1))
    else
      seen_keys="${seen_keys}${key}"$'\n'
    fi
  done <<< "$triples"
}

check4

echo ""
echo "$CRITICAL critical, $WARN warning"
[ "$CRITICAL" -eq 0 ]
