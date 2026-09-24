#!/usr/bin/env bash
# Test runner for forge-gap-since-last-signal.sh
# Pure bash, no test framework dependency.
# Pattern follows forge-permission-lint.test.sh.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../forge-gap-since-last-signal.sh"

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

assert_in_range() {
  local name="$1"; local lo="$2"; local hi="$3"; local actual="$4"
  if [ "$actual" -ge "$lo" ] && [ "$actual" -le "$hi" ]; then
    echo "  ✓ $name ($actual in [$lo, $hi])"
    PASS=$((PASS+1))
  else
    echo "  ✗ $name — expected value in [$lo, $hi], got $actual"
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

# Make a temp vault stub. Returns its path.
mk_vault() {
  local tmp; tmp=$(mktemp -d)
  mkdir -p "$tmp/_shared" "$tmp/PERSO/test-proj"
  echo "$tmp"
}

# Run the script with FORGE_CONF_OVERRIDE pointing at a stub conf.
run_with_vault() {
  local vault="$1"; shift
  local conf; conf=$(mktemp)
  echo "VAULT_PATH=$vault" > "$conf"
  FORGE_CONF_OVERRIDE="$conf" "$SCRIPT" "$@"
  local rc=$?
  rm -f "$conf"
  return $rc
}

set_mtime() {
  # Portable: epoch-second timestamp -> [[CC]YY]MMDDhhmm[.SS] format for touch.
  local f="$1" epoch="$2"
  touch -t "$(date -r "$epoch" '+%Y%m%d%H%M.%S' 2>/dev/null || date -d "@$epoch" '+%Y%m%d%H%M.%S')" "$f"
}

# Sentinel must match script constant
SENTINEL=999999999

echo "Test 1 — empty vault returns sentinel"
vault=$(mk_vault)
out=$(run_with_vault "$vault" 2>&1); rc=$?
assert_eq "exits 0" "0" "$rc"
assert_eq "returns sentinel" "$SENTINEL" "$out"
rm -rf "$vault"

echo ""
echo "Test 2 — single checkpoint, gap = now - mtime (within ±10s)"
vault=$(mk_vault)
NOW=$(date +%s)
TEN_MIN_AGO=$((NOW - 600))
touch "$vault/PERSO/test-proj/current-checkpoint.md"
set_mtime "$vault/PERSO/test-proj/current-checkpoint.md" "$TEN_MIN_AGO"
out=$(run_with_vault "$vault" 2>&1); rc=$?
assert_eq "exits 0" "0" "$rc"
assert_in_range "gap is ~600s" 595 615 "$out"
rm -rf "$vault"

echo ""
echo "Test 3 — multiple sources: most-recent wins"
vault=$(mk_vault)
NOW=$(date +%s)
OLD=$((NOW - 86400))     # 1 day ago
NEWER=$((NOW - 300))     # 5 minutes ago
touch "$vault/PERSO/test-proj/current-checkpoint.md"
touch "$vault/PERSO/test-proj/braindump.md"
set_mtime "$vault/PERSO/test-proj/current-checkpoint.md" "$OLD"
set_mtime "$vault/PERSO/test-proj/braindump.md" "$NEWER"
out=$(run_with_vault "$vault" 2>&1); rc=$?
assert_eq "exits 0" "0" "$rc"
assert_in_range "gap follows newest source (~300s)" 295 315 "$out"
rm -rf "$vault"

echo ""
echo "Test 4 — __pending__ marker contributes nothing"
vault=$(mk_vault)
echo "__pending__" > "$vault/_shared/forge-active"
# Force the marker's mtime to NOW so we'd see a tiny gap if it were counted.
out=$(run_with_vault "$vault" 2>&1); rc=$?
assert_eq "exits 0" "0" "$rc"
assert_eq "returns sentinel (marker ignored)" "$SENTINEL" "$out"
rm -rf "$vault"

echo ""
echo "Test 5 — empty marker file contributes nothing"
vault=$(mk_vault)
touch "$vault/_shared/forge-active"
out=$(run_with_vault "$vault" 2>&1); rc=$?
assert_eq "exits 0" "0" "$rc"
assert_eq "returns sentinel (empty marker ignored)" "$SENTINEL" "$out"
rm -rf "$vault"

echo ""
echo "Test 6 — JSON marker contributes (counted as a signal)"
vault=$(mk_vault)
NOW=$(date +%s)
ONE_HOUR_AGO=$((NOW - 3600))
echo '{"session_id":"abc","project":"test-proj","started_at":"2026-05-22T10:00:00+0200","tmux_pane":"%0"}' > "$vault/_shared/forge-active"
set_mtime "$vault/_shared/forge-active" "$ONE_HOUR_AGO"
out=$(run_with_vault "$vault" 2>&1); rc=$?
assert_eq "exits 0" "0" "$rc"
assert_in_range "gap is ~3600s" 3595 3615 "$out"
rm -rf "$vault"

echo ""
echo "Test 7 — cross-project signals counted (project-agnostic)"
vault=$(mk_vault)
mkdir -p "$vault/PRO/other-proj"
NOW=$(date +%s)
OLD=$((NOW - 86400))
NEWER=$((NOW - 60))
touch "$vault/PERSO/test-proj/current-checkpoint.md"
touch "$vault/PRO/other-proj/current-checkpoint.md"
set_mtime "$vault/PERSO/test-proj/current-checkpoint.md" "$OLD"
set_mtime "$vault/PRO/other-proj/current-checkpoint.md" "$NEWER"
out=$(run_with_vault "$vault" 2>&1); rc=$?
assert_eq "exits 0" "0" "$rc"
assert_in_range "gap follows newer cross-project signal (~60s)" 55 75 "$out"
rm -rf "$vault"

echo ""
echo "Test 8 — future-dated mtime ignored (clock skew safety)"
vault=$(mk_vault)
NOW=$(date +%s)
PAST=$((NOW - 300))
FUTURE=$((NOW + 3600))
touch "$vault/PERSO/test-proj/current-checkpoint.md"
touch "$vault/PERSO/test-proj/braindump.md"
set_mtime "$vault/PERSO/test-proj/current-checkpoint.md" "$PAST"
set_mtime "$vault/PERSO/test-proj/braindump.md" "$FUTURE"
out=$(run_with_vault "$vault" 2>&1); rc=$?
assert_eq "exits 0" "0" "$rc"
assert_in_range "gap uses past source, ignores future-dated (~300s)" 295 315 "$out"
rm -rf "$vault"

echo ""
echo "Test 9 — --verbose emits per-source breakdown"
vault=$(mk_vault)
NOW=$(date +%s)
touch "$vault/PERSO/test-proj/current-checkpoint.md"
set_mtime "$vault/PERSO/test-proj/current-checkpoint.md" "$((NOW - 600))"
out=$(run_with_vault "$vault" --verbose 2>&1); rc=$?
assert_eq "exits 0" "0" "$rc"
assert_contains "header present" "Forge gap-since-last-signal" "$out"
assert_contains "per-source section present" "Per-source signals" "$out"
assert_contains "checkpoint listed" "PERSO/test-proj/current-checkpoint.md" "$out"
rm -rf "$vault"

echo ""
echo "Test 10 — missing forge.conf exits non-zero"
out=$(FORGE_CONF_OVERRIDE=/nonexistent/forge.conf "$SCRIPT" 2>&1); rc=$?
assert_eq "exits 1" "1" "$rc"
assert_contains "error message present" "forge.conf not found" "$out"

echo ""
echo "==================================="
echo "Passed: $PASS  Failed: $FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
