#!/bin/bash
# forge-vault-write-guard — PreToolUse hook
#
# Rejects Write/Edit tool calls against $VAULT_PATH/** when invoked from the
# main Forge session. Forces operational vault writes through Tier 1 silent
# scripts (forge-context.sh subcommands) or Tier 2 subagent dispatch
# (forge-keeper), preventing the noisy diff render + permission prompt that
# inline Edit/Write produces.
#
# Subagent detection: the hook input's `session_id` is compared against the
# forge-active marker's `session_id` (which is set to the main session's id at
# Forge activation per forge/SKILL.md step 1c). Match → main session, enforce.
# Mismatch → subagent, allow.
#
# Composes alongside forge-vault-plan-guard.sh — independent paths, first to
# deny wins.
#
# Fail-safe: any missing precondition (Forge inactive, no marker, marker
# pending or legacy plain-string, no session_id on input, etc.) → allow.

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

case "$FILE_PATH" in
  "$VAULT_PATH"/*) ;;
  *) exit 0 ;;
esac

MARKER="$VAULT_PATH/_shared/forge-active"
[ -f "$MARKER" ] || exit 0

MARKER_CONTENT="$(cat "$MARKER" 2>/dev/null)"
# Treat empty / __pending__ / non-JSON legacy plain-string markers as
# "Forge not fully active" → allow.
[ -z "$MARKER_CONTENT" ] && exit 0
[ "$MARKER_CONTENT" = "__pending__" ] && exit 0
echo "$MARKER_CONTENT" | jq -e . >/dev/null 2>&1 || exit 0

MAIN_SESSION_ID="$(echo "$MARKER_CONTENT" | jq -r '.session_id // empty')"
[ -z "$MAIN_SESSION_ID" ] && exit 0

HOOK_SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // empty')"
[ -z "$HOOK_SESSION_ID" ] && exit 0

# Subagent dispatch (different session_id) → allow.
[ "$HOOK_SESSION_ID" != "$MAIN_SESSION_ID" ] && exit 0

# Main session attempting a raw Write/Edit on a vault file → deny.
REASON="[forge] Vault write from main session — dispatch a forge-keeper subagent instead.
File: $FILE_PATH
Protocol: core/references/vault-write-protocol.md
Pattern: Tier 1 (silent forge-context.sh subcommand if one exists) → Tier 2 (forge-keeper subagent dispatch — collapses to one Agent block) → Tier 3 (inline Edit/Write, last resort).
The diff renders + permission prompts produced by inline Edit/Write on vault files drown the conversation and duplicate what the user already sees in Obsidian. The subagent dispatch eliminates both."

jq -n --arg reason "$REASON" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": $reason
  }
}'
exit 0
