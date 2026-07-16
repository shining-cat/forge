#!/usr/bin/env bash
# Test runner for the WELLNESS_ENABLED master-switch gate on the enforcement
# path (task 2026-07-10-wellness-strike-gate-ignores-enabled-flag).
#
# Regression this locks: before the fix, ONLY wellness-reset.sh honored
# WELLNESS_ENABLED; the PreToolUse strike/break path fired regardless of the
# flag, so a "disabled" coach still struck and blocked tool calls (friction
# 2026-07-08, 2026-07-10). The gate now lives at the top of wellness-timer's
# main() and reads is_wellness_enabled() from preferences.py.
#
# Two layers:
#   A. Unit  — preferences.is_wellness_enabled(conf_path) strict "==true"
#              semantics (true / false / absent-key / missing-file).
#   B. Integration — a full main() run under a sandbox HOME with an overdue
#              (90-min) last break:
#        - WELLNESS_ENABLED=false → exit 0, NO deny (the required guard)
#        - key absent             → exit 0, NO deny (strict = disabled)
#        - WELLNESS_ENABLED=true  → exit 2, strike deny (enforcement intact)
#
# The integration cases stub `sysctl` (so auto-break wake/boot detection is
# deterministic — the fake epoch predates the fake last-break, so no auto
# credit clears the strike) and `osascript` (so notify.sh stays silent) via a
# PATH-prepended bin dir. screen_state binary is absent under the sandbox, so
# the activity-monitor path is skipped.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_FILE="$SCRIPT_DIR/../wellness-timer.py"
PREFS_FILE="$SCRIPT_DIR/../preferences.py"

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
  if echo "$haystack" | grep -qF "$needle"; then
    echo "  ✓ $name"
    PASS=$((PASS+1))
  else
    echo "  ✗ $name — output didn't contain '$needle'"
    echo "    Got: $haystack"
    FAIL=$((FAIL+1))
  fi
}

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "  ✗ $name — output unexpectedly contained '$needle'"
    echo "    Got: $haystack"
    FAIL=$((FAIL+1))
  else
    echo "  ✓ $name"
    PASS=$((PASS+1))
  fi
}

# ── Layer A — is_wellness_enabled() unit tests ──────────────────────────────

# Call preferences.is_wellness_enabled with an explicit conf path.
run_flag() {
  local conf="$1"
  python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('pref', '$PREFS_FILE')
pref = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pref)
print(pref.is_wellness_enabled('$conf'))
" 2>/dev/null
}

echo "=== A. preferences.is_wellness_enabled (strict ==true) ==="

TMP_CONF_DIR=$(mktemp -d)

echo ""
echo "Check A1 — WELLNESS_ENABLED=true → True"
printf 'VAULT_PATH=/x\nWELLNESS_ENABLED=true\n' > "$TMP_CONF_DIR/true.conf"
assert_eq "true → enabled" "True" "$(run_flag "$TMP_CONF_DIR/true.conf")"

echo ""
echo "Check A2 — WELLNESS_ENABLED=false → False"
printf 'VAULT_PATH=/x\nWELLNESS_ENABLED=false\n' > "$TMP_CONF_DIR/false.conf"
assert_eq "false → disabled" "False" "$(run_flag "$TMP_CONF_DIR/false.conf")"

echo ""
echo "Check A3 — key absent → False (strict)"
printf 'VAULT_PATH=/x\n' > "$TMP_CONF_DIR/absent.conf"
assert_eq "absent key → disabled" "False" "$(run_flag "$TMP_CONF_DIR/absent.conf")"

echo ""
echo "Check A4 — forge.conf missing → False"
assert_eq "missing file → disabled" "False" "$(run_flag "$TMP_CONF_DIR/does-not-exist.conf")"

echo ""
echo "Check A5 — trailing whitespace tolerated (WELLNESS_ENABLED=true  ) → True"
printf 'WELLNESS_ENABLED=true  \n' > "$TMP_CONF_DIR/ws.conf"
assert_eq "whitespace-stripped true → enabled" "True" "$(run_flag "$TMP_CONF_DIR/ws.conf")"

rm -rf "$TMP_CONF_DIR"

# ── Layer B — full main() integration under a sandbox HOME ──────────────────

# Build a sandbox HOME. $1 = flag mode: "true" | "false" | "absent".
# Plants forge.conf, an overdue (90-min) prefs file, and sysctl/osascript
# stubs on a PATH-prepended bin dir.
mk_home() {
  local mode="$1"
  local home; home=$(mktemp -d)
  mkdir -p "$home/.claude/scripts" "$home/.claude/bin" "$home/bin" \
           "$home/vault/_shared"

  # forge.conf
  {
    echo "VAULT_PATH=$home/vault"
    case "$mode" in
      true)  echo "WELLNESS_ENABLED=true" ;;
      false) echo "WELLNESS_ENABLED=false" ;;
      absent) : ;;  # no flag line
    esac
  } > "$home/.claude/forge.conf"

  # Overdue prefs: last break 90 min ago, escalating_strike, 60-min interval.
  # 90 >= 60 + 15 strike_delay → strike level.
  python3 -c "
import json, time
home = '$home'
now = time.time()
past = time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime(now - 90*60))
prefs = {
    'coach_name': 'TestCoach',
    'persona': 'professional',
    'interruption_level': 'escalating_strike',
    'break_interval_minutes': 60,
    'micro_break_interval_minutes': 25,
    'strike_delay_minutes': 15,
    'calendar_enabled': False,
    'activity_monitor_enabled': False,
    'last_break_timestamp': past,
    'last_micro_break_timestamp': past,
    'last_reminder_timestamp': past,
    'strike_active': False,
    'strike_cleared_at': None,
    'snooze_count': 0,
    'break_history': [],
}
with open(home + '/vault/_shared/wellness-preferences.json', 'w') as f:
    json.dump(prefs, f)
"

  # sysctl stub — fake wake/boot far in the past (epoch 1e9 = 2001), so the
  # ISO string compares < the 2026 fake last-break and never credits an auto
  # break that would clear the strike.
  cat > "$home/bin/sysctl" <<'EOF'
#!/bin/bash
echo "{ sec = 1000000000, usec = 0 } Sun Sep  9 03:46:40 2001"
EOF
  chmod +x "$home/bin/sysctl"

  # osascript stub — swallow notify.sh so no real macOS banner fires.
  cat > "$home/bin/osascript" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$home/bin/osascript"

  echo "$home"
}

# Run wellness-timer main() with a plain Bash PreToolUse payload.
# Echoes "<exit_code>||<stdout>".
run_hook() {
  local home="$1"
  local out rc
  out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"echo test"}}' \
    | HOME="$home" PATH="$home/bin:$PATH" python3 "$HOOK_FILE" 2>/dev/null)
  rc=$?
  printf '%s||%s' "$rc" "$out"
}

echo ""
echo "=== B. wellness-timer main() gate (overdue 90-min break) ==="

# ── B1 — disabled: MUST NOT block (the required regression guard) ───────────
echo ""
echo "Check B1 — WELLNESS_ENABLED=false → exit 0, no strike (must not block)"
HOME_DIR=$(mk_home false)
res=$(run_hook "$HOME_DIR")
assert_eq       "exit code 0"      "0" "${res%%||*}"
assert_not_contains "no deny emitted" '"permissionDecision": "deny"' "${res#*||}"
rm -rf "$HOME_DIR"

# ── B2 — key absent: strict disabled, MUST NOT block ───────────────────────
echo ""
echo "Check B2 — key absent → exit 0, no strike (strict = disabled)"
HOME_DIR=$(mk_home absent)
res=$(run_hook "$HOME_DIR")
assert_eq       "exit code 0"      "0" "${res%%||*}"
assert_not_contains "no deny emitted" '"permissionDecision": "deny"' "${res#*||}"
rm -rf "$HOME_DIR"

# ── B3 — enabled: enforcement intact, overdue break DOES strike ────────────
echo ""
echo "Check B3 — WELLNESS_ENABLED=true → exit 2, strike deny (enforcement intact)"
HOME_DIR=$(mk_home true)
res=$(run_hook "$HOME_DIR")
assert_eq    "exit code 2"          "2" "${res%%||*}"
assert_contains "strike deny emitted" '"permissionDecision": "deny"' "${res#*||}"
rm -rf "$HOME_DIR"

echo ""
echo "Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ]
