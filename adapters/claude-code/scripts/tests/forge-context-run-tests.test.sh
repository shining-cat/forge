#!/usr/bin/env bash
# Tests forge-context.sh run-tests (suite runner subcommand).
#
# Behavior under test:
#  - Discovers every */tests/*.test.sh under FORGE_REPO and runs each.
#  - No filter, mixed suite → runs all, exit 1 when any file fails.
#  - Filter (substring on path) → runs only matching files.
#  - Passing-only subset → exit 0.
#  - Filter matching nothing → exit 2 with a named message.
#  - FORGE_REPO with no test files → exit 2 with a named message.
#  - Failing test's own output is surfaced (not swallowed).

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_CONTEXT="$SCRIPT_DIR/../forge-context.sh"

PASS=0; FAIL=0

setup() {
  TMP=$(mktemp -d)
  TMP_CONF="$TMP/forge.conf"
  REPO="$TMP/repo"
  mkdir -p "$TMP/_shared" "$REPO/a/tests" "$REPO/b/tests"
  {
    echo "VAULT_PATH=$TMP"
    echo "FORGE_REPO=$REPO"
    echo "REPO_ROOTS=$TMP/repos"
  } > "$TMP_CONF"
  export FORGE_CONF_OVERRIDE="$TMP_CONF"

  # A passing test file.
  cat > "$REPO/a/tests/alpha.test.sh" <<'EOF'
#!/usr/bin/env bash
echo "ALPHA-RAN"
echo "── Total: 2 pass, 0 fail ──"
exit 0
EOF
  # A failing test file that prints a distinctive marker.
  cat > "$REPO/b/tests/beta.test.sh" <<'EOF'
#!/usr/bin/env bash
echo "BETA-RAN"
echo "BETA-FAILURE-MARKER"
echo "── Total: 1 pass, 1 fail ──"
exit 1
EOF
  # A passing test that CONSUMES stdin — regression for the while-read/heredoc
  # stdin-inheritance bug. Sorts before alpha/beta, so if the runner lets the
  # child inherit the loop's stdin, this eats the remaining paths and alpha/beta
  # never run.
  cat > "$REPO/a/tests/aa-stdin.test.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
echo "AA-RAN"
exit 0
EOF
  chmod +x "$REPO/a/tests/aa-stdin.test.sh" "$REPO/a/tests/alpha.test.sh" "$REPO/b/tests/beta.test.sh"
}

teardown() {
  rm -rf "$TMP"
  unset FORGE_CONF_OVERRIDE
}

check() { # desc, condition-already-evaluated via $?
  if [ "$1" -eq 0 ]; then echo "  ✓ $2"; PASS=$((PASS+1))
  else echo "  ✗ $2"; FAIL=$((FAIL+1)); fi
}

# ── Mixed suite, no filter ─────────────────────────────────────────────
setup
out=$("$FORGE_CONTEXT" run-tests </dev/null 2>&1); rc=$?
[ "$rc" -eq 1 ]; check $? "mixed suite → exit 1"
echo "$out" | grep -q "aa-stdin.test.sh"; check $? "stdin-consuming test ran (PASS line present)"
echo "$out" | grep -q "alpha.test.sh"; check $? "runs alpha (continues past stdin eater)"
echo "$out" | grep -q "beta.test.sh"; check $? "runs beta (continues past stdin eater)"
echo "$out" | grep -q "BETA-FAILURE-MARKER"; check $? "surfaces failing test output"
echo "$out" | grep -Eiq "2 passed"; check $? "tally reports 2 passed"
echo "$out" | grep -Eiq "1 failed"; check $? "tally reports 1 failed"
teardown

# ── Filter to passing subset ───────────────────────────────────────────
setup
out=$("$FORGE_CONTEXT" run-tests alpha </dev/null 2>&1); rc=$?
[ "$rc" -eq 0 ]; check $? "filter=alpha (passing only) → exit 0"
echo "$out" | grep -q "alpha.test.sh"; check $? "filter runs alpha"
echo "$out" | grep -q "beta.test.sh" && r=1 || r=0
check $r "filter excludes beta"
teardown

# ── Filter matching nothing ────────────────────────────────────────────
setup
out=$("$FORGE_CONTEXT" run-tests zzz-no-such </dev/null 2>&1); rc=$?
[ "$rc" -eq 2 ]; check $? "no filter match → exit 2"
echo "$out" | grep -qi "no test files matched"; check $? "no-match message present"
teardown

# ── No test files in repo at all ───────────────────────────────────────
setup
rm -f "$REPO/a/tests/aa-stdin.test.sh" "$REPO/a/tests/alpha.test.sh" "$REPO/b/tests/beta.test.sh"
out=$("$FORGE_CONTEXT" run-tests </dev/null 2>&1); rc=$?
[ "$rc" -eq 2 ]; check $? "empty repo → exit 2"
echo "$out" | grep -qi "no test files found"; check $? "no-tests-found message present"
teardown

echo ""
echo "── Total: $PASS pass, $FAIL fail ──"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
