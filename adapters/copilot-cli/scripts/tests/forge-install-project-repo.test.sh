#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="$SCRIPT_DIR/../../install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/copilot" "$TMP/FORGE-DEV" "$TMP/FORGE-DEV-2" "$TMP/FORGE-TOOLING" "$TMP/vault"
git -C "$TMP/FORGE-DEV" init -q
git -C "$TMP/FORGE-DEV-2" init -q
git -C "$TMP/FORGE-TOOLING" init -q

COPILOT_HOME="$TMP/copilot" "$INSTALL" --vault-path "$TMP/vault" \
  --forge-project-repo "$TMP/FORGE-DEV" >/dev/null
grep -qx "FORGE_PROJECT_REPO=$TMP/FORGE-DEV" "$TMP/copilot/forge.conf"
while IFS= read -r reference; do
  [ -f "$TMP/copilot/skills/forge/$reference" ] || {
    echo "missing installed Forge reference: $reference" >&2
    exit 1
  }
done < <(grep -oE 'references/[a-z0-9-]+\.md' \
  "$SCRIPT_DIR/../../skills/forge/SKILL.md" | sort -u)

printf 'CUSTOM_SETTING=preserved\n' >> "$TMP/copilot/forge.conf"
COPILOT_HOME="$TMP/copilot" "$INSTALL" --vault-path "$TMP/vault" >/dev/null
grep -qx "FORGE_PROJECT_REPO=$TMP/FORGE-DEV" "$TMP/copilot/forge.conf"
COPILOT_HOME="$TMP/copilot" "$INSTALL" --vault-path "$TMP/vault" \
  --forge-project-repo "$TMP/FORGE-DEV-2" >/dev/null
grep -qx "FORGE_PROJECT_REPO=$TMP/FORGE-DEV-2" "$TMP/copilot/forge.conf"
grep -qx 'CUSTOM_SETTING=preserved' "$TMP/copilot/forge.conf"
[ "$(grep -c '^FORGE_PROJECT_REPO=' "$TMP/copilot/forge.conf")" -eq 1 ]

if COPILOT_HOME="$TMP/copilot" "$INSTALL" --vault-path "$TMP/vault" \
  --forge-project-repo "$TMP/missing" >/dev/null 2>&1; then
  echo "invalid checkout unexpectedly accepted" >&2
  exit 1
fi
if COPILOT_HOME="$TMP/copilot" "$INSTALL" --vault-path "$TMP/vault" \
  --forge-project-repo "" >/dev/null 2>&1; then
  echo "empty checkout unexpectedly accepted" >&2
  exit 1
fi
grep -qx "FORGE_PROJECT_REPO=$TMP/FORGE-DEV-2" "$TMP/copilot/forge.conf"

echo "Forge project checkout installer tests passed"
