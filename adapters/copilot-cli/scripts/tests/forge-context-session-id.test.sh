#!/usr/bin/env bash
# Test runner for forge-context.sh session-id resolution.
# Copilot CLI exposes the id to tool subprocesses as COPILOT_AGENT_SESSION_ID.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../forge-context.sh"
PASS=0; FAIL=0
assert_eq() { local n="$1" exp="$2" act="$3"
  if [ "$exp" = "$act" ]; then echo "  ✓ $n"; PASS=$((PASS+1))
  else echo "  ✗ $n — expected [$exp] got [$act]"; FAIL=$((FAIL+1)); fi; }

V=$(mktemp -d); mkdir -p "$V/_shared" "$V/PERSO/forge"
C=$(mktemp); printf 'VAULT_PATH=%s\n' "$V" > "$C"

echo "=== set-marker session id ==="
env -u COPILOT_SESSION_ID COPILOT_AGENT_SESSION_ID=agent-1 FORGE_CONF_OVERRIDE="$C" \
  "$SCRIPT" set-marker active forge >/dev/null 2>&1
assert_eq "falls back to COPILOT_AGENT_SESSION_ID" "agent-1" "$(jq -r '.session_id' "$V/_shared/forge-active")"

COPILOT_SESSION_ID=hook-1 COPILOT_AGENT_SESSION_ID=agent-1 FORGE_CONF_OVERRIDE="$C" \
  "$SCRIPT" set-marker active forge >/dev/null 2>&1
assert_eq "COPILOT_SESSION_ID wins when both set" "hook-1" "$(jq -r '.session_id' "$V/_shared/forge-active")"

env -u COPILOT_SESSION_ID -u COPILOT_AGENT_SESSION_ID FORGE_CONF_OVERRIDE="$C" \
  "$SCRIPT" set-marker active forge >/dev/null 2>&1
assert_eq "empty when neither is set" "" "$(jq -r '.session_id' "$V/_shared/forge-active")"

rm -rf "$V" "$C"
echo "Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ]
