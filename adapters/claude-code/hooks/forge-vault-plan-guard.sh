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

PROJECT="$(tr -d '[:space:]' < "$MARKER")"
case "$PROJECT" in
  ""|"__pending__") exit 0 ;;
esac

case "$FILE_PATH" in
  */.claude/plans/*|*/docs/plans/*) ;;
  *) exit 0 ;;
esac

case "$PROJECT" in
  forge|Forge) ENV="PERSO" ;;
  FINN)        ENV="SCHIBSTED" ;;
  SimpleHIIT|boombox|Keyboard) ENV="PERSO" ;;
  *)           ENV="" ;;
esac

if [ -n "$ENV" ]; then
  PROJECT_DIR="$VAULT_PATH/$ENV/$PROJECT/tasks/open/"
else
  PROJECT_DIR="$VAULT_PATH/_shared/tasks/open/  (no ENV mapping for project '$PROJECT' — see SKILL.md)"
fi

REASON="[forge] Plan/design files must go in the vault, not ${FILE_PATH}.
Active project: $PROJECT
Use: $PROJECT_DIR for project work
Or:  $VAULT_PATH/_shared/tasks/open/ for cross-project work"

jq -n --arg reason "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
