#!/usr/bin/env bash
# Test runner for forge-permission-lint.sh
# Pure bash, no test framework dependency.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINTER="$SCRIPT_DIR/../forge-permission-lint.sh"
FIXTURES="$SCRIPT_DIR/fixtures"

PASS=0
FAIL=0

assert_exit() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ✓ $name"
    PASS=$((PASS+1))
  else
    echo "  ✗ $name — expected exit $expected, got $actual"
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

echo "Check 1 — Write/Edit single-* not crossing /"
out=$("$LINTER" --file "$FIXTURES/check1-bad.json" 2>&1); rc=$?
assert_exit "check1-bad: exits 1 (critical)" "1" "$rc"
assert_contains "check1-bad: reports the bad Write pattern" "Write(*/.claude/skills/wellness-coach/scripts/*)" "$out"
assert_contains "check1-bad: reports the bad Edit pattern" "Edit(*/foo/*)" "$out"

out=$("$LINTER" --file "$FIXTURES/check1-good.json" 2>&1); rc=$?
assert_exit "check1-good: exits 0" "0" "$rc"

echo ""
echo "Check 2 — Bash leading-* literal"
out=$("$LINTER" --file "$FIXTURES/check2-bad.json" 2>&1); rc=$?
assert_exit "check2-bad: exits 1" "1" "$rc"
assert_contains "check2-bad: reports the bad Bash pattern" "Bash(*forge-context.sh*)" "$out"

out=$("$LINTER" --file "$FIXTURES/check2-good.json" 2>&1); rc=$?
assert_exit "check2-good: exits 0" "0" "$rc"

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
