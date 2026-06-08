#!/usr/bin/env bash
# Test runner for wellness-timer.py's welcome-back emit-shape branching on
# Stop vs PreToolUse context (regression for user-reported 2026-06-08 bug).
#
# Background: `_credit_auto_break` runs welcome-back emit at the end of its
# body. Pre-fix, it unconditionally called `emit_allow()` — which emits
# `hookSpecificOutput.hookEventName: "PreToolUse"` + `permissionDecision`.
# When the parent hook is Stop (user returns from a long absence with no
# tool calls during the welcome window, so the Stop hook fires and credits
# the break), Claude Code rejects the payload:
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
#   1. is_stop=True  + welcome-back credit → Stop-shaped (top-level
#      systemMessage only, NO hookSpecificOutput, NO permissionDecision)
#   2. is_stop=False + welcome-back credit → PreToolUse-shaped
#      (hookSpecificOutput.hookEventName="PreToolUse",
#       permissionDecision="allow", with systemMessage)

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

raw = buf.getvalue().strip()
parsed = json.loads(raw)
print('keys:', ','.join(sorted(parsed.keys())))
print('has_hso:', 'hookSpecificOutput' in parsed)
print('has_systemMessage:', 'systemMessage' in parsed)
hso = parsed.get('hookSpecificOutput', {}) or {}
print('hookEventName:', hso.get('hookEventName', 'MISSING'))
print('permissionDecision:', hso.get('permissionDecision', 'MISSING'))
" 2>/dev/null
}

echo "=== wellness-timer welcome-back emit-shape branching ==="

# ── 1 — Stop context: emit is Stop-shaped (top-level systemMessage only) ──
echo ""
echo "Check 1 — is_stop=True welcome-back → Stop-shaped payload"
out=$(run_credit_capture "True")
keys=$(echo   "$out" | grep '^keys:'                | head -1)
has_hso=$(echo "$out" | grep '^has_hso:'             | head -1)
has_sm=$(echo  "$out" | grep '^has_systemMessage:'   | head -1)
hen=$(echo     "$out" | grep '^hookEventName:'       | head -1)
pd=$(echo      "$out" | grep '^permissionDecision:'  | head -1)
assert_eq "only systemMessage key"     "keys: systemMessage"        "$keys"
assert_eq "no hookSpecificOutput"      "has_hso: False"             "$has_hso"
assert_eq "systemMessage present"      "has_systemMessage: True"    "$has_sm"
assert_eq "no hookEventName field"     "hookEventName: MISSING"     "$hen"
assert_eq "no permissionDecision"      "permissionDecision: MISSING" "$pd"

# ── 2 — PreToolUse context: emit is PreToolUse-shaped (no regression) ────
echo ""
echo "Check 2 — is_stop=False welcome-back → PreToolUse-shaped payload"
out=$(run_credit_capture "False")
keys=$(echo   "$out" | grep '^keys:'                | head -1)
has_hso=$(echo "$out" | grep '^has_hso:'             | head -1)
has_sm=$(echo  "$out" | grep '^has_systemMessage:'   | head -1)
hen=$(echo     "$out" | grep '^hookEventName:'       | head -1)
pd=$(echo      "$out" | grep '^permissionDecision:'  | head -1)
assert_eq "both top-level keys"        "keys: hookSpecificOutput,systemMessage" "$keys"
assert_eq "hookSpecificOutput present" "has_hso: True"              "$has_hso"
assert_eq "systemMessage present"      "has_systemMessage: True"    "$has_sm"
assert_eq "hookEventName=PreToolUse"   "hookEventName: PreToolUse"  "$hen"
assert_eq "permissionDecision=allow"   "permissionDecision: allow"  "$pd"

echo ""
echo "Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ]
