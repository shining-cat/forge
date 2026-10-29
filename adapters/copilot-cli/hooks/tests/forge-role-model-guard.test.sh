#!/usr/bin/env bash
# Synthetic PreToolUse envelopes: the live task hook envelope is unverified.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_FILE="$SCRIPT_DIR/../forge-role-model-guard.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" payload="$3" output rc decision
  output="$(printf '%s' "$payload" | bash "$HOOK_FILE" 2>&1)"
  rc=$?
  if [ "$expected" = ask ]; then
    decision="$(printf '%s' "$output" | jq -er '
      .hookSpecificOutput |
      select(.hookEventName == "PreToolUse") |
      select(.permissionDecisionReason | contains("omit") and
        contains("model") and contains("frontmatter") and
        contains("user explicitly") and contains("one-off override")) |
      .permissionDecision' 2>/dev/null)"
  else
    decision="$output"
  fi
  if [ "$rc" -eq 0 ] && [ "$decision" = "$expected" ]; then
    printf '  ✓ %s\n' "$name"; PASS=$((PASS+1))
  else
    printf '  ✗ %s — exit %s, output: %s\n' "$name" "$rc" "$output"
    FAIL=$((FAIL+1))
  fi
}

echo "=== forge-role-model-guard ==="
for role in architect debugger impl keeper refiner release reviewer toolsmith; do
  check "$role + model → ask" ask \
    "{\"tool_name\":\"task\",\"tool_input\":{\"agent_type\":\"forge-$role\",\"model\":\"test-model\"}}"
  check "$role without model → silent" "" \
    "{\"tool_name\":\"task\",\"tool_input\":{\"agent_type\":\"forge-$role\"}}"
done
for tool in Task TASK tAsK; do
  check "$tool casing → ask" ask \
    "{\"tool_name\":\"$tool\",\"tool_input\":{\"agent_type\":\"forge-impl\",\"model\":\"test-model\"}}"
done
for role in explore general-purpose forge-other forge-impl-extra prefix-forge-impl; do
  check "$role + model → silent" "" \
    "{\"tool_name\":\"task\",\"tool_input\":{\"agent_type\":\"$role\",\"model\":\"test-model\"}}"
done
# Presence, not truthiness or equality with the baked model, triggers confirmation.
for model in 'null' '""' '"same-as-baked"'; do
  check "explicit model $model → ask" ask \
    "{\"tool_name\":\"task\",\"tool_input\":{\"agent_type\":\"forge-keeper\",\"model\":$model}}"
done
check "non-task tool → silent" "" \
  '{"tool_name":"Bash","tool_input":{"agent_type":"forge-impl","model":"test-model"}}'
for payload in '' '{bad json' '{}' 'null' '[]' 'true' \
  '{"tool_name":"task","tool_input":' \
  '{"tool_name":42,"tool_input":{"agent_type":"forge-impl","model":"test-model"}}' \
  '{"tool_name":"task","tool_input":"not an object"}' \
  '{"tool_name":"task","tool_input":null}' \
  '{"tool_name":"task","tool_input":{"agent_type":[],"model":"test-model"}}' \
  '{"tool_name":"task","tool_input":{"model":"test-model"}}' \
  '{"tool_name":"task","tool_input":{"agent_type":"forge-impl","model":"test-model"}} {}'; do
  check "invalid/missing payload fields ($payload) → silent" "" "$payload"
done

echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
