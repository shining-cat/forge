#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../../install.sh"
SOURCE_HOOKS="$SCRIPT_DIR/../../hooks/forge.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home/.copilot/hooks" "$TMP/vault"

cat > "$TMP/home/.copilot/hooks/forge.json" <<'JSON'
{
  "version": 1,
  "hooks": {
    "PreToolUse": [
      {"type":"command","bash":"/custom/my-hook.sh","matcher":"Write|Edit"},
      {"type":"command","bash":"${COPILOT_HOME:-$HOME/.copilot}/hooks/forge-vault-write-guard.sh","matcher":"Write|Edit"},
      {"type":"command","bash":"${COPILOT_HOME:-$HOME/.copilot}/hooks/forge-vault-plan-guard.sh","matcher":"Write|Edit"}
    ],
    "customEvent": [{"type":"command","bash":"/custom/untouched.sh"}]
  }
}
JSON

HOME="$TMP/home" COPILOT_HOME="$TMP/home/.copilot" bash "$INSTALL_SH" --vault-path "$TMP/vault" > "$TMP/install.log"
installed="$TMP/home/.copilot/hooks/forge.json"

jq -e '
  .hooks.PreToolUse as $hooks |
  ([$hooks[] | select(.bash | contains("forge-vault-write-guard.sh"))] | length) == 0 and
  ([$hooks[] | select(.bash | contains("forge-vault-plan-guard.sh"))] | length) == 1 and
  ([$hooks[] | select(.bash == "/custom/my-hook.sh")] | length) == 1 and
  .hooks.customEvent[0].bash == "/custom/untouched.sh"
' "$installed" > /dev/null

expected="$(jq -c '[.hooks.PreToolUse[] | select(.bash | contains("forge-")) | .bash]' "$SOURCE_HOOKS")"
actual="$(jq -c '[.hooks.PreToolUse[] | select(.bash | contains("forge-")) | .bash]' "$installed")"
[[ "$expected" == "$actual" ]]
printf '  ✓ retired Copilot vault-write hook; preserved plan guard and unrelated hooks\n'
