#!/usr/bin/env bash
# Test runner for forge-context.sh weekly-wrap-due + mark-weekly-wrap-done.
# Pure bash, no test framework. Pattern follows forge-gap-since-last-signal.test.sh.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../forge-context.sh"

PASS=0
FAIL=0

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ✓ $name"
    PASS=$((PASS+1))
  else
    echo "  ✗ $name — expected '$expected', got '$actual'"
    FAIL=$((FAIL+1))
  fi
}

assert_contains() {
  local name="$1"; local needle="$2"; local haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "  ✓ $name"
    PASS=$((PASS+1))
  else
    echo "  ✗ $name — output didn't contain: $needle"
    echo "    Got: $haystack"
    FAIL=$((FAIL+1))
  fi
}

mk_vault() {
  local tmp; tmp=$(mktemp -d)
  mkdir -p "$tmp/_shared" "$tmp/PERSO/test-proj"
  echo "$tmp"
}

# Run with a stub forge.conf so the script reads our temp VAULT_PATH.
# Subcommand and args go after.
run_cmd() {
  local vault="$1"; shift
  local conf; conf=$(mktemp)
  echo "VAULT_PATH=$vault" > "$conf"
  FORGE_CONF_OVERRIDE="$conf" "$SCRIPT" "$@"
  local rc=$?
  rm -f "$conf"
  return $rc
}

# Same as run_cmd but capturing output.
run_cmd_out() {
  local vault="$1"; shift
  local conf; conf=$(mktemp)
  echo "VAULT_PATH=$vault" > "$conf"
  FORGE_CONF_OVERRIDE="$conf" "$SCRIPT" "$@" 2>&1
  rm -f "$conf"
}

# Run with both a custom gap-days override and the conf.
run_cmd_out_with_gap() {
  local vault="$1"; local gap="$2"; shift 2
  local conf; conf=$(mktemp)
  echo "VAULT_PATH=$vault" > "$conf"
  FORGE_CONF_OVERRIDE="$conf" FORGE_WEEKLY_WRAP_GAP_DAYS="$gap" "$SCRIPT" "$@" 2>&1
  rm -f "$conf"
}

# ── weekly-wrap-due ────────────────────────────────────────────────────

echo "Test 1 — weekly-wrap-due: returns 'due' when runtime file missing"
vault=$(mk_vault)
out=$(run_cmd_out "$vault" weekly-wrap-due); rc=$?
assert_eq "exits 0" "0" "$rc"
assert_eq "outputs 'due'" "due" "$out"
rm -rf "$vault"

echo "Test 2 — weekly-wrap-due: returns 'due' when timestamp is null"
vault=$(mk_vault)
echo '{"last_weekly_wrap_timestamp": null, "last_weekly_wrap_week": null}' > "$vault/_shared/forge-runtime.json"
out=$(run_cmd_out "$vault" weekly-wrap-due)
assert_eq "outputs 'due' (null ts)" "due" "$out"
rm -rf "$vault"

echo "Test 3 — weekly-wrap-due: returns 'not-due' when timestamp is fresh (today)"
vault=$(mk_vault)
now_ts=$(date "+%Y-%m-%dT%H:%M:%S")
printf '{"last_weekly_wrap_timestamp": "%s", "last_weekly_wrap_week": "2026-W22"}\n' "$now_ts" > "$vault/_shared/forge-runtime.json"
out=$(run_cmd_out "$vault" weekly-wrap-due)
assert_eq "outputs 'not-due' (fresh ts)" "not-due" "$out"
rm -rf "$vault"

echo "Test 4 — weekly-wrap-due: returns 'due' when timestamp is old (10 days ago)"
vault=$(mk_vault)
old_ts=$(date -v-10d "+%Y-%m-%dT%H:%M:%S" 2>/dev/null || date -d "10 days ago" "+%Y-%m-%dT%H:%M:%S")
printf '{"last_weekly_wrap_timestamp": "%s", "last_weekly_wrap_week": "2026-W20"}\n' "$old_ts" > "$vault/_shared/forge-runtime.json"
out=$(run_cmd_out "$vault" weekly-wrap-due)
assert_eq "outputs 'due' (10-day-old ts)" "due" "$out"
rm -rf "$vault"

echo "Test 5 — weekly-wrap-due: gap=0 forces 'due' even with fresh timestamp"
vault=$(mk_vault)
now_ts=$(date "+%Y-%m-%dT%H:%M:%S")
printf '{"last_weekly_wrap_timestamp": "%s", "last_weekly_wrap_week": "2026-W22"}\n' "$now_ts" > "$vault/_shared/forge-runtime.json"
out=$(run_cmd_out_with_gap "$vault" 0 weekly-wrap-due)
assert_eq "outputs 'due' (gap=0 override)" "due" "$out"
rm -rf "$vault"

echo "Test 6 — weekly-wrap-due: malformed timestamp treated as 'due'"
vault=$(mk_vault)
echo '{"last_weekly_wrap_timestamp": "not-a-date", "last_weekly_wrap_week": null}' > "$vault/_shared/forge-runtime.json"
out=$(run_cmd_out "$vault" weekly-wrap-due)
assert_eq "outputs 'due' (malformed)" "due" "$out"
rm -rf "$vault"

# ── mark-weekly-wrap-done ─────────────────────────────────────────────

echo "Test 7 — mark-weekly-wrap-done: creates file when missing"
vault=$(mk_vault)
out=$(run_cmd_out "$vault" mark-weekly-wrap-done)
assert_contains "stdout reports marked" "marked:" "$out"
if [ -f "$vault/_shared/forge-runtime.json" ]; then
  echo "  ✓ runtime file created"
  PASS=$((PASS+1))
  ts=$(jq -r '.last_weekly_wrap_timestamp' "$vault/_shared/forge-runtime.json" 2>/dev/null)
  wk=$(jq -r '.last_weekly_wrap_week' "$vault/_shared/forge-runtime.json" 2>/dev/null)
  assert_contains "timestamp populated" "$(date "+%Y-%m-%d")" "$ts"
  case "$wk" in
    *-W*) echo "  ✓ ISO week populated (looks like YYYY-WNN: $wk)"; PASS=$((PASS+1)) ;;
    *)    echo "  ✗ ISO week looks wrong (got: $wk)"; FAIL=$((FAIL+1)) ;;
  esac
else
  echo "  ✗ runtime file NOT created"
  FAIL=$((FAIL+1))
fi
rm -rf "$vault"

echo "Test 8 — mark-weekly-wrap-done: after mark, weekly-wrap-due returns 'not-due'"
vault=$(mk_vault)
run_cmd "$vault" mark-weekly-wrap-done >/dev/null
out=$(run_cmd_out "$vault" weekly-wrap-due)
assert_eq "weekly-wrap-due returns 'not-due'" "not-due" "$out"
rm -rf "$vault"

echo "Test 9 — mark-weekly-wrap-done: idempotent — re-run preserves shape, updates ts"
vault=$(mk_vault)
run_cmd "$vault" mark-weekly-wrap-done >/dev/null
first_ts=$(jq -r '.last_weekly_wrap_timestamp' "$vault/_shared/forge-runtime.json")
sleep 1
run_cmd "$vault" mark-weekly-wrap-done >/dev/null
second_ts=$(jq -r '.last_weekly_wrap_timestamp' "$vault/_shared/forge-runtime.json")
if [ "$first_ts" != "$second_ts" ]; then
  echo "  ✓ timestamp updated on re-run ($first_ts → $second_ts)"
  PASS=$((PASS+1))
else
  echo "  ✗ timestamp unchanged on re-run (both $first_ts)"
  FAIL=$((FAIL+1))
fi
# File should still be valid JSON with both required keys
if jq -e '.last_weekly_wrap_timestamp and .last_weekly_wrap_week' "$vault/_shared/forge-runtime.json" >/dev/null 2>&1; then
  echo "  ✓ JSON still valid with both keys"
  PASS=$((PASS+1))
else
  echo "  ✗ JSON invalid or missing keys after re-run"
  FAIL=$((FAIL+1))
fi
rm -rf "$vault"

echo "Test 10 — mark-weekly-wrap-done: preserves other keys when present"
vault=$(mk_vault)
echo '{"unrelated_key": "preserve me", "last_weekly_wrap_timestamp": null}' > "$vault/_shared/forge-runtime.json"
run_cmd "$vault" mark-weekly-wrap-done >/dev/null
unrelated=$(jq -r '.unrelated_key' "$vault/_shared/forge-runtime.json")
assert_eq "unrelated key preserved" "preserve me" "$unrelated"
rm -rf "$vault"

echo ""
echo "===== Results: $PASS passed, $FAIL failed ====="
[ "$FAIL" -eq 0 ]
