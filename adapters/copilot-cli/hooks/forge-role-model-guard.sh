#!/bin/bash
# forge-role-model-guard — PreToolUse hook (task)
#
# An explicit model overrides the installed Forge role's frontmatter binding.
# Ask for confirmation; a user-requested one-off override remains possible.
# Always-on for the eight Forge roles, not gated on a forge-active marker.
#
# Recorded task events confirm task / agent_type / model, but the live task
# PreToolUse envelope is unverified. Use the existing hooks' tool_input shape
# and tolerate tool-name casing. Any parse problem or non-match allows silently.

set -euo pipefail

INPUT="$(cat)" || exit 0

# Slurp so empty input and multiple JSON values cannot yield a partial match.
# Keep jq inside a conditional: set -e must not turn parse errors into failures.
if ! printf '%s' "$INPUT" | jq -se '
  select(length == 1) | .[0] |
  select(type == "object") |
  select(.tool_name | type == "string") |
  select(.tool_name | ascii_downcase == "task") |
  .tool_input | select(type == "object") |
  select(.agent_type | type == "string") |
  select(.agent_type | test("^forge-(architect|debugger|impl|keeper|refiner|release|reviewer|toolsmith)$")) |
  has("model")
' >/dev/null 2>&1; then
  exit 0
fi

REASON='[forge] An explicit model parameter overrides the Forge role frontmatter model and defeats its configured tier binding. Please omit `model` and let the installed agent definition select the model, unless the user explicitly asked for a one-off override. Approve only for that user-requested override.'

jq -n --arg reason "$REASON" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "permissionDecisionReason": $reason
  }
}' || exit 0
exit 0
