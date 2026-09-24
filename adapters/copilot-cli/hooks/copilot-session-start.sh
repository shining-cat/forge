#!/usr/bin/env bash
set -euo pipefail
COPILOT_DIR="${COPILOT_HOME:-$HOME/.copilot}"
INPUT="$(cat)"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.sessionId // .session_id // empty')"
export COPILOT_SESSION_ID="$SESSION_ID"
CONTEXT="[$(date '+%Y-%m-%d %H:%M %Z')] Forge Copilot adapter loaded. Use the /forge skill for Forge session entry."
jq -n --arg context "$CONTEXT" '{"additionalContext": $context}'
