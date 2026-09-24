#!/usr/bin/env bash
# Tests forge-context.sh weekly-wrap-line (deterministic entry-summary gate)
# + the EOW_LAST_HOUR_MIN narrowing in do_wrap_up_state.
# (2026-06-12-eow-wrap-line-strict-gate)
#
# weekly-wrap-line emits the verbatim nudge ONLY when wrap-up-state is
# eow_window/past_eow AND weekly-wrap-due == due; empty otherwise. This removes
# Petra's judgment from the loop (she echoes script output).
#
# Time-of-day note: a couple of cases derive preferred_end_of_day from "now +
# offset"; if run within ~1 min of midnight the HH:MM wrap could skew a case.
# Acceptable — this is the first coverage of an otherwise time/day-dependent fn.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../forge-context.sh"
PASS=0; FAIL=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then echo "  ✓ $name"; PASS=$((PASS+1));
  else echo "  ✗ $name — expected '$expected', got '$actual'"; FAIL=$((FAIL+1)); fi
}
assert_empty() {
  local name="$1" actual="$2"
  if [ -z "$actual" ]; then echo "  ✓ $name"; PASS=$((PASS+1));
  else echo "  ✗ $name — expected empty, got '$actual'"; FAIL=$((FAIL+1)); fi
}
assert_contains() {
  local name="$1" needle="$2" hay="$3"
  if echo "$hay" | grep -qF "$needle"; then echo "  ✓ $name"; PASS=$((PASS+1));
  else echo "  ✗ $name — '$hay' lacked '$needle'"; FAIL=$((FAIL+1)); fi
}

epoch_to_stamp() { date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$1" +%Y%m%d%H%M.%S; }
epoch_to_hm()    { date -r "$1" +%H:%M 2>/dev/null || date -d "@$1" +%H:%M; }

# Build a vault whose wrap-up-state inputs are controlled.
#   $1 eod_offset_min (now + offset = preferred_end_of_day; negative = past EOD)
#   $2 session_age_min (marker mtime backdated this many minutes)
#   $3 runtime: "due" (no runtime file) | "fresh" (just-wrapped)
mk_vault() {
  local eod_off="$1" sess_age="$2" runtime="$3"
  local tmp; tmp=$(mktemp -d)
  mkdir -p "$tmp/_shared" "$tmp/PERSO/test-proj"
  printf '{"session_id":"s","project":"test-proj","started_at":"x","tmux_pane":null}' > "$tmp/_shared/forge-active"
  local m_epoch; m_epoch=$(( $(date +%s) - sess_age*60 ))
  touch -t "$(epoch_to_stamp "$m_epoch")" "$tmp/_shared/forge-active"
  local e_epoch; e_epoch=$(( $(date +%s) + eod_off*60 ))
  printf '{"preferred_end_of_day":"%s"}' "$(epoch_to_hm "$e_epoch")" > "$tmp/_shared/wellness-preferences.json"
  if [ "$runtime" = "fresh" ]; then
    printf '{"last_weekly_wrap_timestamp":"%s"}' "$(date +%Y-%m-%dT%H:%M:%S)" > "$tmp/_shared/forge-runtime.json"
  fi
  echo "$tmp"
}

# Run a subcommand with EOW_DAY + EOW_LAST_HOUR_MIN overrides in conf.
run_cfg() {
  local vault="$1" eow_day="$2" eow_last="$3"; shift 3
  local conf; conf=$(mktemp)
  { echo "VAULT_PATH=$vault"; echo "EOW_DAY=$eow_day"; echo "EOW_LAST_HOUR_MIN=$eow_last"; } > "$conf"
  # stdout is the gate contract; stderr carries an unrelated "no project repo"
  # startup warning (test vault has no code repo) — drop it.
  FORGE_CONF_OVERRIDE="$conf" "$SCRIPT" "$@" 2>/dev/null
  rm -f "$conf"
}

TODAY_DOW=$(date +%u)
OTHER_DOW=$(( TODAY_DOW % 7 + 1 ))   # any different day-of-week

echo "=== weekly-wrap-line ==="

# 1. EOW day, last hour, due → emits the nudge
v=$(mk_vault 30 90 due)
out=$(run_cfg "$v" "$TODAY_DOW" 60 weekly-wrap-line)
assert_contains "gate open (eow_window + due) → nudge emitted" "/forge-weekly" "$out"
rm -rf "$v"

# 2. too_early (session just started) → empty
v=$(mk_vault 30 10 due)
out=$(run_cfg "$v" "$TODAY_DOW" 60 weekly-wrap-line)
assert_empty "too_early → empty (the 2026-06-12 friction case)" "$out"
rm -rf "$v"

# 3. EOW day, last hour, but already wrapped (not-due) → empty
v=$(mk_vault 30 90 fresh)
out=$(run_cfg "$v" "$TODAY_DOW" 60 weekly-wrap-line)
assert_empty "not-due → empty" "$out"
rm -rf "$v"

# 4. Not EOW day (eod_window but not eow) → empty
v=$(mk_vault 30 90 due)
out=$(run_cfg "$v" "$OTHER_DOW" 60 weekly-wrap-line)
assert_empty "non-EOW day → empty" "$out"
rm -rf "$v"

# 5. EOW day but BEFORE the last-hour band (narrowing) → empty
#    eod in 45 min, EOW_LAST_HOUR_MIN=30 → eod_window, not eow.
v=$(mk_vault 45 90 due)
out=$(run_cfg "$v" "$TODAY_DOW" 30 weekly-wrap-line)
assert_empty "EOW day, outside last-hour band → empty (narrowing)" "$out"
rm -rf "$v"

# 6. past EOD on EOW day → emits (past_eow)
v=$(mk_vault -5 90 due)
out=$(run_cfg "$v" "$TODAY_DOW" 60 weekly-wrap-line)
assert_contains "past_eow + due → nudge emitted" "/forge-weekly" "$out"
rm -rf "$v"

echo ""
echo "=== do_wrap_up_state EOW narrowing ==="

# Inside the last-hour band on EOW day → eow_window
v=$(mk_vault 20 90 due)
assert_eq "eod in 20min, last-hour=30 → eow_window" "eow_window" "$(run_cfg "$v" "$TODAY_DOW" 30 wrap-up-state)"
rm -rf "$v"

# Outside the band on EOW day → eod_window (not eow)
v=$(mk_vault 45 90 due)
assert_eq "eod in 45min, last-hour=30 → eod_window (no weekly-wrap)" "eod_window" "$(run_cfg "$v" "$TODAY_DOW" 30 wrap-up-state)"
rm -rf "$v"

echo ""
echo "── Total: $PASS pass, $FAIL fail ──"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
