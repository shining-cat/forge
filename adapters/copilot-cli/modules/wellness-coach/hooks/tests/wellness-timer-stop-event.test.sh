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
#   4. emit_stop_progress displays a timeline message without a user turn
#   5. emit_stop_progress explicitly allows Stop after the progress line

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

# ── 4 — Stop displays a persistent progress message ─────────────────────
echo ""
echo "Check 4 — emit_stop_progress emits a Pip timeline message"
out=$(run_py "
import sys, json, io
buf = io.StringIO()
sys.stdout = buf
try:
    wt.emit_stop_progress('Coach', ['hello from stop', 'take a break'])
except SystemExit:
    pass
sys.stdout = sys.__stdout__
parsed = [json.loads(line) for line in buf.getvalue().splitlines()]
print(parsed[0].get('type', 'MISSING'))
print(parsed[0].get('message', ''))
print(parsed[1].get('decision', 'MISSING'))
")
assert_eq "progress event" "progress" "$(echo "$out" | head -1)"
assert_eq "complete reminder" "Coach: hello from stop take a break" "$(echo "$out" | sed -n '2p')"
assert_eq "no forced continuation" "allow" "$(echo "$out" | tail -1)"

# ── 5 — only a progress event and Stop decision remain ───────────────────
echo ""
echo "Check 5 — emit_stop_progress has no synthetic user prompt"
out=$(run_py "
import sys, json, io
buf = io.StringIO()
sys.stdout = buf
try:
    wt.emit_stop_progress('Coach', ['check'])
except SystemExit:
    pass
sys.stdout = sys.__stdout__
parsed = [json.loads(line) for line in buf.getvalue().splitlines()]
print('count:', len(parsed))
print('keys:', ','.join(sorted(parsed[0])))
print('keys:', ','.join(sorted(parsed[1])))
")
assert_eq "one progress and one decision" "count: 2" "$(echo "$out" | head -1)"
assert_eq "progress fields" "keys: message,type" "$(echo "$out" | sed -n '2p')"
assert_eq "no reason field" "keys: decision" "$(echo "$out" | tail -1)"

echo ""
echo "Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ]
