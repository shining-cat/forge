#!/usr/bin/env bash
set -euo pipefail
COPILOT_DIR="${COPILOT_HOME:-$HOME/.copilot}"
INPUT="$(cat)"
PROMPT="$(printf '%s' "$INPUT" | jq -r '.transformedPrompt // .prompt // empty')"
TIME="$(date '+%Y-%m-%d %H:%M %Z')"
MARKER=""
if [ -f "$COPILOT_DIR/forge.conf" ]; then
  VAULT_PATH="$(grep '^VAULT_PATH=' "$COPILOT_DIR/forge.conf" | cut -d= -f2- || true)"
  if [ -n "$VAULT_PATH" ] && [ -s "$VAULT_PATH/_shared/forge-active" ]; then
    PROJECT="$(jq -r '.project // empty' "$VAULT_PATH/_shared/forge-active" 2>/dev/null || true)"
    if [ -n "$PROJECT" ]; then
      MARKER=" [Forge active for $PROJECT]"
    fi
  fi
fi
PREFIX="[Current local time: $TIME]$MARKER"
if printf '%s' "$INPUT" | jq -e '.transformedPrompt' >/dev/null 2>&1; then
  jq -n --arg prompt "$PROMPT" --arg prefix "$PREFIX" '{"modifiedTransformedPrompt": ($prefix + "\n" + $prompt)}'
else
  jq -n --arg prompt "$PROMPT" --arg prefix "$PREFIX" '{"modifiedPrompt": ($prefix + "\n" + $prompt)}'
fi
