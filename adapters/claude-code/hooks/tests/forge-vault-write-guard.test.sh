#!/usr/bin/env bash
# Test runner for forge-vault-write-guard.sh PreToolUse hook.
#
# Strategy: invoke the hook via bash with stdin carrying a PreToolUse-shaped
# JSON payload, plus a stubbed $HOME pointing at a tmpdir containing fake
# forge.conf + forge-active marker. Test the deny/allow decisions.
#
# Cases:
#   1. main session + vault path (Edit)            → DENY
#   2. main session + vault path (Write)           → DENY
#   3. subagent (different session_id) + vault    → ALLOW
#   4. main session + non-vault path              → ALLOW
#   5. Forge inactive (no marker)                  → ALLOW
#   6. Marker is __pending__                       → ALLOW
#   7. Marker is legacy plain-string               → ALLOW
#   8. Tool other than Write/Edit (Bash)           → ALLOW
#   9. Empty session_id on input                  → ALLOW (fail-safe)

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_FILE="$SCRIPT_DIR/../forge-vault-write-guard.sh"

PASS=0
FAIL=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ✓ $name"
    PASS=$((PASS+1))
  else
    echo "  ✗ $name — expected '$expected', got '$actual'"
    FAIL=$((FAIL+1))
  fi
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -q -- "$needle"; then
    echo "  ✓ $name"
    PASS=$((PASS+1))
  else
    echo "  ✗ $name — did not find '$needle' in output"
    FAIL=$((FAIL+1))
  fi
}

# Build a fake test environment with a configurable marker + vault path.
# Args: <marker_content> <session_id_in_marker>
setup_env() {
  TMP_HOME="$(mktemp -d)"
  TMP_VAULT="$(mktemp -d)"
  mkdir -p "$TMP_HOME/.claude" "$TMP_VAULT/_shared"
  echo "VAULT_PATH=$TMP_VAULT" > "$TMP_HOME/.claude/forge.conf"
  local marker="$1"
  if [ -n "$marker" ]; then
    printf '%s' "$marker" > "$TMP_VAULT/_shared/forge-active"
  fi
}

teardown_env() {
  rm -rf "$TMP_HOME" "$TMP_VAULT"
}

# Invoke hook with given JSON input + return its stdout.
# Hooks rely on $HOME — override it for the invocation.
invoke() {
  local input="$1"
  echo "$input" | HOME="$TMP_HOME" bash "$HOOK_FILE" 2>/dev/null
}

echo "=== forge-vault-write-guard ==="

# --- Case 1: main session + vault path + Edit → DENY ---
setup_env '{"session_id":"main-1","project":"forge"}'
INPUT="$(jq -n --arg path "$TMP_VAULT/tasks/x.md" '{
  session_id: "main-1",
  tool_name: "Edit",
  tool_input: {file_path: $path}
}')"
OUT="$(invoke "$INPUT")"
assert_contains "case 1: main+vault+Edit emits deny" '"permissionDecision": "deny"' "$OUT"
assert_contains "case 1: deny reason names forge-keeper" 'forge-keeper subagent' "$OUT"
teardown_env

# --- Case 2: main session + vault path + Write → DENY ---
setup_env '{"session_id":"main-2","project":"forge"}'
INPUT="$(jq -n --arg path "$TMP_VAULT/BACKLOG.md" '{
  session_id: "main-2",
  tool_name: "Write",
  tool_input: {file_path: $path}
}')"
OUT="$(invoke "$INPUT")"
assert_contains "case 2: main+vault+Write emits deny" '"permissionDecision": "deny"' "$OUT"
teardown_env

# --- Case 3: subagent (different session_id) + vault → ALLOW ---
setup_env '{"session_id":"main-3","project":"forge"}'
INPUT="$(jq -n --arg path "$TMP_VAULT/tasks/y.md" '{
  session_id: "subagent-xyz",
  tool_name: "Edit",
  tool_input: {file_path: $path}
}')"
OUT="$(invoke "$INPUT")"
assert_eq "case 3: subagent invocation produces no output (allow)" "" "$OUT"
teardown_env

# --- Case 4: main session + non-vault path → ALLOW ---
setup_env '{"session_id":"main-4","project":"forge"}'
INPUT="$(jq -n '{
  session_id: "main-4",
  tool_name: "Edit",
  tool_input: {file_path: "/tmp/something-not-in-vault.txt"}
}')"
OUT="$(invoke "$INPUT")"
assert_eq "case 4: non-vault path produces no output (allow)" "" "$OUT"
teardown_env

# --- Case 5: Forge inactive (no marker) → ALLOW ---
setup_env ""
INPUT="$(jq -n --arg path "$TMP_VAULT/tasks/z.md" '{
  session_id: "main-5",
  tool_name: "Edit",
  tool_input: {file_path: $path}
}')"
OUT="$(invoke "$INPUT")"
assert_eq "case 5: no marker → allow" "" "$OUT"
teardown_env

# --- Case 6: marker is __pending__ → ALLOW ---
setup_env "__pending__"
INPUT="$(jq -n --arg path "$TMP_VAULT/tasks/p.md" '{
  session_id: "main-6",
  tool_name: "Edit",
  tool_input: {file_path: $path}
}')"
OUT="$(invoke "$INPUT")"
assert_eq "case 6: __pending__ marker → allow" "" "$OUT"
teardown_env

# --- Case 7: marker is legacy plain-string → ALLOW ---
setup_env "forge"
INPUT="$(jq -n --arg path "$TMP_VAULT/tasks/l.md" '{
  session_id: "main-7",
  tool_name: "Edit",
  tool_input: {file_path: $path}
}')"
OUT="$(invoke "$INPUT")"
assert_eq "case 7: legacy plain-string marker → allow (not valid JSON)" "" "$OUT"
teardown_env

# --- Case 8: tool other than Write/Edit → ALLOW ---
setup_env '{"session_id":"main-8","project":"forge"}'
INPUT="$(jq -n --arg path "$TMP_VAULT/tasks/b.md" '{
  session_id: "main-8",
  tool_name: "Bash",
  tool_input: {command: "ls"}
}')"
OUT="$(invoke "$INPUT")"
assert_eq "case 8: non-Write/Edit tool → allow" "" "$OUT"
teardown_env

# --- Case 9: empty session_id on input → ALLOW (fail-safe) ---
setup_env '{"session_id":"main-9","project":"forge"}'
INPUT="$(jq -n --arg path "$TMP_VAULT/tasks/e.md" '{
  tool_name: "Edit",
  tool_input: {file_path: $path}
}')"
OUT="$(invoke "$INPUT")"
assert_eq "case 9: missing session_id on input → allow (fail-safe)" "" "$OUT"
teardown_env

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
