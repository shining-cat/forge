#!/bin/bash
# forge-vault-plan-guard — PreToolUse hook
# Rejects Write/Edit to **/.claude/plans/** or **/docs/plans/** when Forge is active.
# Allows everything else (no output = implicit allow).

set -euo pipefail

INPUT="$(cat)"

TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name // empty')"
case "$TOOL_NAME" in
  Write|Edit) ;;
  *) exit 0 ;;
esac

FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')"
[ -z "$FILE_PATH" ] && exit 0

FORGE_CONF="$HOME/.claude/forge.conf"
[ -f "$FORGE_CONF" ] || exit 0

VAULT_PATH="$(grep '^VAULT_PATH=' "$FORGE_CONF" | head -1 | cut -d= -f2- || true)"
[ -z "$VAULT_PATH" ] && exit 0

MARKER="$VAULT_PATH/_shared/forge-active"
[ -f "$MARKER" ] || exit 0

# Resolve project name via the shared helper — handles JSON, legacy
# plain-string, empty, and __pending__ markers uniformly.
if [ ! -f "$HOME/.claude/scripts/forge-context.sh" ]; then
  exit 0
fi
# shellcheck disable=SC1091
source "$HOME/.claude/scripts/forge-context.sh"
PROJECT="$(extract_marker_project)"
[ -z "$PROJECT" ] && exit 0

case "$FILE_PATH" in
  */.claude/plans/*|*/docs/plans/*) ;;
  *) exit 0 ;;
esac

# Resolve project vault dir dynamically — no hardcoded brand list.
PROJECT_VAULT="$(get_vault_dir "$PROJECT" 2>/dev/null || true)"
if [ -n "$PROJECT_VAULT" ] && [ -d "$PROJECT_VAULT" ]; then
  PROJECT_DIR="$PROJECT_VAULT/tasks/open/"
else
  PROJECT_DIR="$VAULT_PATH/_shared/tasks/open/  (no vault dir found for project '$PROJECT' — see SKILL.md)"
fi

REASON="[forge] Plan/design files must go in the vault, not ${FILE_PATH}.
Active project: $PROJECT
Use: $PROJECT_DIR for project work
Or:  $VAULT_PATH/_shared/tasks/open/ for shared/cross-cutting work"

jq -n --arg reason "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
