#!/usr/bin/env bash
# Test runner for wellness-timer.py's Stop-event handling (Slice 5 of
# wellness-coverage-audit, 2026-06-05).
#
# Strategy: invoke wellness-timer.py via python3 with stdin carrying either
# a PreToolUse-shaped or Stop-shaped JSON payload, then test the helper
# functions in isolation. Full-hook integration tests are harder (the hook
# reads from $VAULT_PATH/_shared/wellness-{preferences,runtime}.json and
# expects activity_log + formatting modules at sibling paths), so we focus
# on the new functions: is_stop_event() detection + emit_stop_message()
# output shape.
#
# Five assertions:
#   1. is_stop_event({"hook_event_name": "Stop"}) → True
#   2. is_stop_event({"tool_name": "Bash"}) → False (PreToolUse)
#   3. is_stop_event({}) → False (defensive)
#   4. emit_stop_message output has hookEventName: "Stop" + systemMessage
#   5. emit_stop_message output does NOT have permissionDecision

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_FILE="$SCRIPT_DIR/../wellness-timer.py"

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

# Run a python snippet that imports wellness-timer.py and tests a function.
# stdin is a JSON dict.
run_py() {
  python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('wt', '$HOOK_FILE')
wt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wt)
$1
" 2>/dev/null
}

echo "=== wellness-timer Stop-event handling ==="

# ── 1 — is_stop_event detects the Stop marker ───────────────────────────
echo ""
echo "Check 1 — is_stop_event({'hook_event_name': 'Stop'}) → True"
out=$(run_py "print(wt.is_stop_event({'hook_event_name': 'Stop'}))")
assert_eq "detected Stop" "True" "$out"

# ── 2 — is_stop_event returns False for PreToolUse-shaped input ─────────
echo ""
echo "Check 2 — is_stop_event({'tool_name': 'Bash'}) → False"
out=$(run_py "print(wt.is_stop_event({'tool_name': 'Bash', 'tool_input': {}}))")
assert_eq "PreToolUse not flagged Stop" "False" "$out"

# ── 3 — is_stop_event returns False for empty input (defensive) ─────────
echo ""
echo "Check 3 — is_stop_event({}) → False (defensive)"
out=$(run_py "print(wt.is_stop_event({}))")
assert_eq "empty input not flagged Stop" "False" "$out"

# ── 4 — emit_stop_message output shape: top-level systemMessage only ────
# Schema-correct shape per Claude Code's hook output spec: Stop has no
# `hookSpecificOutput.Stop` schema entry, so we emit just `{"systemMessage": ...}`.
# Emitting an unknown hookSpecificOutput.hookEventName triggers Claude Code
# to dump the expected-schema as an error on every Stop event (regression
# from the original PR #76 ship; fixed in the hotfix PR).
echo ""
echo "Check 4 — emit_stop_message emits top-level systemMessage"
out=$(run_py "
import sys, json, io
buf = io.StringIO()
sys.stdout = buf
try:
    wt.emit_stop_message('hello from stop')
except SystemExit:
    pass
sys.stdout = sys.__stdout__
parsed = json.loads(buf.getvalue())
print(parsed.get('systemMessage', 'MISSING'))
print('has_hookSpecificOutput:', 'hookSpecificOutput' in parsed)
")
msg=$(echo "$out" | head -1)
has_hso=$(echo "$out" | tail -1)
assert_eq "systemMessage preserved"   "hello from stop"               "$msg"
assert_eq "no hookSpecificOutput key" "has_hookSpecificOutput: False" "$has_hso"

# ── 5 — emit_stop_message output is minimal — no other unexpected keys ─
echo ""
echo "Check 5 — emit_stop_message output has only systemMessage"
out=$(run_py "
import sys, json, io
buf = io.StringIO()
sys.stdout = buf
try:
    wt.emit_stop_message('check')
except SystemExit:
    pass
sys.stdout = sys.__stdout__
parsed = json.loads(buf.getvalue())
keys = sorted(parsed.keys())
print('keys:', ','.join(keys))
")
assert_eq "only systemMessage key present" "keys: systemMessage" "$out"

echo ""
echo "Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ]
