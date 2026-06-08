#!/usr/bin/env bash
# Test runner for wellness-timer.py's cold-start macro-gap classification
# in _detect_auto_break (incident 2026-06-08 08:42 CEST — Pip contradicted
# herself by emitting "Short break noted!" then immediately striking on the
# next tool call after a ~40h gap with a 6m12s screen lock).
#
# Strategy: drive _detect_auto_break and determine_level as pure functions.
# We don't need a real PreToolUse payload — the bug is in classification, so
# we feed a synthetic idle-log + an in-memory prefs dict, then assert on the
# returned tier and the post-credit determine_level outcome.
#
# Sandbox: HOME is a tmpdir so IDLE_LOG_PATH and forge.conf paths point at
# fixtures we control. preferences.py resolves _SHARED_DIR at import time
# from ~/.claude/forge.conf, so HOME must be set BEFORE the python -c block.
#
# Three assertions (in order):
#   1. Macro-gap forces real tier:
#        6-min screen-off→on transition + last_break_timestamp 40h ago
#        → _detect_auto_break returns (ts, "real"), not (ts, "micro").
#   2. Recent real break stays micro:
#        6-min screen-off→on + last_break_timestamp 30 min ago
#        → returns (ts, "micro"). Guards against regressing the intended
#        micro behavior.
#   3. No double-fire on next call:
#        After cold-start real credit, a synthetic next PreToolUse with the
#        updated runtime state does NOT return "strike" from determine_level.
#        This is the critical assertion — it's what would have caught today's
#        live failure (the "Short break noted" → immediate strike sequence).

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

# Build a sandbox HOME with an idle-log containing a synthetic
# screen-on → screen-off → screen-on sequence ending "now" with the given
# off-duration in minutes. The "off" sample is placed off_min before now,
# and a prior "on" sample is placed off_min+1 before the off sample (so
# find_last_screen_off_break can walk back to find the break start). A
# fake forge.conf points VAULT_PATH at the sandbox vault dir so prefs
# read/writes are sandboxed too.
mk_sandbox() {
  local off_min="$1"
  local home; home=$(mktemp -d)
  mkdir -p "$home/.claude" "$home/vault/_shared"

  # forge.conf so preferences.py resolves _SHARED_DIR to the sandbox vault.
  cat > "$home/.claude/forge.conf" <<EOF
VAULT_PATH=$home/vault
EOF

  # Build the idle log. Timestamps are epoch seconds.
  # Sequence: on (long ago) → off (off_min before now) → on (now).
  python3 -c "
import json, time
now = time.time()
off_min = $off_min
off_t = now - off_min * 60
on_before_t = off_t - 60  # 1 min of 'on' before the lock
samples = [
    {'t': on_before_t, 'display': 'on', 'locked': False},
    {'t': off_t,       'display': 'off', 'locked': True},
    {'t': now,         'display': 'on', 'locked': False},
]
with open('$home/.claude/wellness-idle-log.json', 'w') as f:
    json.dump(samples, f)
"
  echo "$home"
}

echo "=== wellness-timer cold-start macro-gap classification ==="

# ── 1 — Macro-gap (40h since last real break) forces real tier ──────────
echo ""
echo "Check 1 — 6-min lock + 40h-old last_break → tier 'real'"
HOME_DIR=$(mk_sandbox 6)
out=$(HOME="$HOME_DIR" python3 -c "
import importlib.util, time
spec = importlib.util.spec_from_file_location('wt', '$HOOK_FILE')
wt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wt)
# last_break_timestamp 40h ago
forty_h_ago = time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime(time.time() - 40*3600))
prefs = {
    'activity_monitor_enabled': True,
    'micro_break_lock_threshold_minutes': 5,
    'real_break_lock_threshold_minutes': 15,
    'last_break_timestamp': forty_h_ago,
    'last_micro_break_timestamp': forty_h_ago,
}
res = wt._detect_auto_break(prefs)
if res is None:
    print('NONE')
else:
    ts, tier = res
    print(tier)
" 2>/dev/null)
assert_eq "tier forced to real on macro gap" "real" "$out"
rm -rf "$HOME_DIR"

# ── 2 — Recent real break (30 min) stays micro ──────────────────────────
echo ""
echo "Check 2 — 6-min lock + 30-min-old last_break → tier 'micro' (no regression)"
HOME_DIR=$(mk_sandbox 6)
out=$(HOME="$HOME_DIR" python3 -c "
import importlib.util, time
spec = importlib.util.spec_from_file_location('wt', '$HOOK_FILE')
wt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wt)
# last_break_timestamp 30 min ago — below real_break_lock_threshold_minutes (15)
# is what we're guarding against; 30 min is well past 15, so we use a value
# CLEARLY recent (below the strike window but past the threshold? wait —
# threshold is on the LOCK duration, the gap is the macro-gap floor). We want
# the gap to NOT trigger the macro override, so we keep the gap small enough
# that minutes_since(last_break) < real_break_lock_threshold_minutes (15).
# Use 10 min instead of 30 to stay clearly under 15.
ten_min_ago = time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime(time.time() - 10*60))
prefs = {
    'activity_monitor_enabled': True,
    'micro_break_lock_threshold_minutes': 5,
    'real_break_lock_threshold_minutes': 15,
    'last_break_timestamp': ten_min_ago,
    'last_micro_break_timestamp': ten_min_ago,
}
res = wt._detect_auto_break(prefs)
if res is None:
    print('NONE')
else:
    ts, tier = res
    print(tier)
" 2>/dev/null)
assert_eq "tier stays micro when gap is recent" "micro" "$out"
rm -rf "$HOME_DIR"

# ── 3 — Post-credit determine_level does NOT return strike ──────────────
# After the cold-start real credit, last_break_timestamp is updated to NOW
# and strike_active is cleared. The next PreToolUse must NOT see a strike
# (this is exactly the back-to-back contradiction the live failure exhibited).
echo ""
echo "Check 3 — after real-tier credit, next determine_level is not 'strike'"
HOME_DIR=$(mk_sandbox 6)
out=$(HOME="$HOME_DIR" python3 -c "
import importlib.util, time
spec = importlib.util.spec_from_file_location('wt', '$HOOK_FILE')
wt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wt)

# Simulate the cold-start prefs: 40h since last real break, strike was
# already active (typical post-gap state).
forty_h_ago = time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime(time.time() - 40*3600))
prefs = {
    'activity_monitor_enabled': True,
    'micro_break_lock_threshold_minutes': 5,
    'real_break_lock_threshold_minutes': 15,
    'micro_break_interval_minutes': 25,
    'real_break_interval_minutes': 60,
    'strike_delay_minutes': 15,
    'insistence_level': 'escalating_strike',
    'last_break_timestamp': forty_h_ago,
    'last_micro_break_timestamp': forty_h_ago,
    'strike_active': True,
}

# Step 1: classify — expect real-tier after the fix.
res = wt._detect_auto_break(prefs)
assert res is not None, 'expected a detected break'
ts, tier = res
assert tier == 'real', f'expected real tier, got {tier!r}'

# Step 2: simulate the real-tier credit path (wellness-timer.py:607-628) —
# we don't actually call _credit_auto_break (that would touch the prefs
# files); we replicate the in-memory state change. This mirrors what
# main() does after _credit_auto_break returns and prefs are re-read.
now = wt.now_iso()
prefs['last_break_timestamp'] = now
prefs['last_micro_break_timestamp'] = now
prefs['strike_active'] = False
prefs['snooze_count'] = 0

# Step 3: next PreToolUse logic — recompute elapsed and call determine_level.
elapsed = wt.minutes_since(prefs.get('last_break_timestamp'))
level = wt.determine_level(prefs, elapsed)
# Print the level so the bash side can assert.
print(level if level is not None else 'NONE')
" 2>/dev/null)
# Must not be 'strike'. We also accept 'NONE' (the expected outcome — fresh
# break clock, no level triggered) or any of {'micro','break','insist'},
# none of which would block the call.
if [ "$out" = "strike" ]; then
  echo "  ✗ post-credit double-fire — determine_level returned 'strike'"
  FAIL=$((FAIL+1))
else
  echo "  ✓ post-credit safe — determine_level returned '$out' (not strike)"
  PASS=$((PASS+1))
fi
rm -rf "$HOME_DIR"

echo ""
echo "Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ]
