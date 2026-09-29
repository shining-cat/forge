#!/bin/bash
# forge-vault-plan-guard — PreToolUse hook
# Rejects Write/Edit to **/docs/plans/** when Forge is active.
# ($COPILOT_DIR/plans/ is allowed — GitHub Copilot CLI's plan mode pre-allocates there
# natively. Petra's protocol, documented in forge/SKILL.md "Plan storage (Forge
# mode)", ensures plan content lands as a section in a proper vault task file
# regardless of where plan-mode pre-allocates the scratch draft.)
# Allows everything else (no output = implicit allow).

set -euo pipefail

COPILOT_DIR="${COPILOT_HOME:-$HOME/.copilot}"

INPUT="$(cat)"

TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name // empty')"
case "$TOOL_NAME" in
  Write|Edit) ;;
  *) exit 0 ;;
esac

INPUT_TYPE="$(echo "$INPUT" | jq -r '.tool_input | type')"
FILE_PATHS="$(echo "$INPUT" | jq -r '
  .tool_input |
  if type == "object" then .file_path // empty
  elif type == "string" then
    if startswith("*** Begin Patch\n") and (endswith("*** End Patch") or endswith("*** End Patch\n")) then
      split("\n")[] |
      if startswith("*** Add File: ") then ltrimstr("*** Add File: ")
      elif startswith("*** Update File: ") then ltrimstr("*** Update File: ")
      elif startswith("*** Delete File: ") then ltrimstr("*** Delete File: ")
      elif startswith("*** Move to: ") then ltrimstr("*** Move to: ")
      else empty end
    else empty end
  else empty end
')"

FORGE_CONF="$COPILOT_DIR/forge.conf"
[ -f "$FORGE_CONF" ] || exit 0

VAULT_PATH="$(grep '^VAULT_PATH=' "$FORGE_CONF" | head -1 | cut -d= -f2- || true)"
[ -z "$VAULT_PATH" ] && exit 0

MARKER="$VAULT_PATH/_shared/forge-active"
[ -f "$MARKER" ] || exit 0

# Resolve project name via the shared helper — handles JSON, legacy
# plain-string, empty, and __pending__ markers uniformly.
if [ ! -f "$COPILOT_DIR/scripts/forge-context.sh" ]; then
  exit 0
fi
# shellcheck disable=SC1091
source "$COPILOT_DIR/scripts/forge-context.sh"
PROJECT="$(extract_marker_project)"
[ -z "$PROJECT" ] && exit 0

if [ "$INPUT_TYPE" = "string" ] && [ -z "$FILE_PATHS" ]; then
  jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: "[forge] Unrecognized patch input; cannot verify plan paths."}}'
  exit 0
fi

PLAN_FILE=""
while IFS= read -r FILE_PATH; do
  case "$FILE_PATH" in
    */docs/plans/*) PLAN_FILE="$FILE_PATH"; break ;;
  esac
done <<< "$FILE_PATHS"
[ -z "$PLAN_FILE" ] && exit 0

# Resolve project vault dir dynamically — no hardcoded brand list.
PROJECT_VAULT="$(get_vault_dir "$PROJECT" 2>/dev/null || true)"
if [ -n "$PROJECT_VAULT" ] && [ -d "$PROJECT_VAULT" ]; then
  PROJECT_DIR="$PROJECT_VAULT/tasks/open/"
else
  PROJECT_DIR="$VAULT_PATH/_shared/tasks/open/  (no vault dir found for project '$PROJECT' — see SKILL.md)"
fi

REASON="[forge] Plan/design files must go in the vault, not ${PLAN_FILE}.
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
