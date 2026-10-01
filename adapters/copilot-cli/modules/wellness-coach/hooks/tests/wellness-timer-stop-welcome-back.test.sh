#!/usr/bin/env bash
# Test runner for wellness-timer.py's welcome-back emit-shape branching on
# Stop vs PreToolUse context (regression for user-reported 2026-06-08 bug).
#
# Background: `_credit_auto_break` runs welcome-back emit at the end of its
# body. Pre-fix, it unconditionally called `emit_allow()` — which emits
# `hookSpecificOutput.hookEventName: "PreToolUse"` + `permissionDecision`.
# When the parent hook is Stop (user returns from a long absence with no
# tool calls during the welcome window, so the Stop hook fires and credits
# the break), GitHub Copilot CLI rejects the payload:
#   "Stop hook error: Failed to run: Hook returned incorrect event name:
#    expected 'Stop' but got 'PreToolUse'"
#
# Collateral of PR #82 — that PR fixed only the strike-escalation Stop path.
# This test pins the welcome-back path as well.
#
# Strategy: monkey-patch `try_reminder_lock` and `log_event` to bypass
# filesystem state, drive `_credit_auto_break` with an `auto_break`
# timestamp within the 5-minute welcome window, capture stdout, parse JSON,
# assert the emit shape matches the context.
#
# Two assertions:
#   1. is_stop=True  + welcome-back credit → one timeline progress line
#   2. is_stop=False + welcome-back credit → Copilot PreToolUse allow

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

# Run a python snippet that imports wellness-timer.py and calls
# `_credit_auto_break` with isolated side effects.
run_credit_capture() {
  local is_stop_literal="$1"  # "True" or "False"
  python3 -c "
import importlib.util, sys, json, io, time

spec = importlib.util.spec_from_file_location('wt', '$HOOK_FILE')
wt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wt)

# Stub side-effecting helpers so we drive only the emit path.
wt.read_modify_write = lambda fn: None
wt.log_event = lambda *a, **kw: None
class _FD:
    def close(self): pass
wt.try_reminder_lock = lambda: _FD()
wt.notify = lambda *a, **kw: None
wt.get_welcome_back_lines = lambda persona, tier='real': ['welcome back!']
wt.format_box = lambda coach_name, lines, kind: '[BOX]'
wt.center_block = lambda s: s
wt.now_iso = lambda: '2026-06-08T11:00:00'

# auto_break = 1 minute ago — well within the 5-minute welcome window.
auto_break_epoch = time.time() - 60
auto_break = time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime(auto_break_epoch))

prefs = {
    'persona': 'professional',
    'coach_name': 'Coach',
    'strike_active': False,
    'snooze_count': 0,
    'last_micro_break_timestamp': None,
    'break_history': [],
}

buf = io.StringIO()
sys.stdout = buf
try:
    wt._credit_auto_break(prefs, auto_break, None, 'Coach',
                          tier='real', is_stop=$is_stop_literal)
except SystemExit:
    pass
sys.stdout = sys.__stdout__

parsed = [json.loads(line) for line in buf.getvalue().splitlines()]
progress = parsed[0] if $is_stop_literal else {}
result = parsed[-1]
print('count:', len(parsed))
print('keys:', ','.join(sorted(result.keys())))
print('type:', progress.get('type', 'MISSING'))
print('message:', progress.get('message', 'MISSING'))
print('decision:', result.get('decision', 'MISSING'))
hso = result.get('hookSpecificOutput', {}) or {}
print('hookEventName:', hso.get('hookEventName', 'MISSING'))
print('permissionDecision:', result.get('permissionDecision', 'MISSING'))
" 2>/dev/null
}

echo "=== wellness-timer welcome-back emit-shape branching ==="

# ── 1 — Stop context: show timeline progress, not a user-like prompt ────
echo ""
echo "Check 1 — is_stop=True welcome-back → timeline progress"
out=$(run_credit_capture "True")
count=$(echo  "$out" | grep '^count:'                | head -1)
keys=$(echo   "$out" | grep '^keys:'                | head -1)
kind=$(echo   "$out" | grep '^type:'                | head -1)
message=$(echo "$out" | grep '^message:'             | head -1)
decision=$(echo "$out" | grep '^decision:' | head -1)
hen=$(echo     "$out" | grep '^hookEventName:'       | head -1)
pd=$(echo      "$out" | grep '^permissionDecision:'  | head -1)
assert_eq "progress plus decision"     "count: 2"                  "$count"
assert_eq "only Stop decision fields"  "keys: decision"            "$keys"
assert_eq "progress emitted"           "type: progress"            "$kind"
assert_eq "welcome included"           "message: Coach: welcome back!" "$message"
assert_eq "no forced turn"             "decision: allow"           "$decision"
assert_eq "no hookEventName field"     "hookEventName: MISSING"     "$hen"
assert_eq "no permissionDecision"      "permissionDecision: MISSING" "$pd"

# ── 2 — PreToolUse context: allow has Copilot CLI output shape ─────────
echo ""
echo "Check 2 — is_stop=False welcome-back → PreToolUse-shaped payload"
out=$(run_credit_capture "False")
count=$(echo "$out" | grep '^count:'                   | head -1)
keys=$(echo   "$out" | grep '^keys:'                | head -1)
hen=$(echo     "$out" | grep '^hookEventName:'       | head -1)
pd=$(echo      "$out" | grep '^permissionDecision:'  | head -1)
assert_eq "single permission decision" "count: 1" "$count"
assert_eq "only permission decision"   "keys: permissionDecision" "$keys"
assert_eq "no hookEventName field"     "hookEventName: MISSING"     "$hen"

echo ""
echo "Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ]
