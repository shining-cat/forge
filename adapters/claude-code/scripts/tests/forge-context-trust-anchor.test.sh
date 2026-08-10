#!/usr/bin/env bash
# Tests forge-context.sh trust-anchor subcommand / do_trust_anchor function.
#
# trust-anchor computes the longest common *directory* prefix of VAULT_PATH plus
# every REPO_ROOTS entry (colon-separated). This is the folder a Forge user
# trusts ONCE so parallel agent-team fan-out panes — which inherit the lead
# session's cwd — never re-hit Claude Code's folder-trust gate.
# See task: 2026-08-07-pretrust-parallel-fanout-folder-gate.
#
# Contract:
#   - Prints the common-prefix dir + exit 0 when it's a real, safe anchor.
#   - Rejects (exit non-zero, empty stdout) when the prefix is $HOME, an
#     ancestor of $HOME, "/", or doesn't exist on disk — an over-broad or
#     bogus anchor is worse than none (caller falls back to no -c / in-process).

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_CONTEXT="$SCRIPT_DIR/../forge-context.sh"

PASS=0; FAIL=0

setup() {
  TMP=$(mktemp -d)
  TMP_CONF="$TMP/forge.conf"
  export FORGE_CONF_OVERRIDE="$TMP_CONF"
}

teardown() {
  rm -rf "$TMP"
  unset FORGE_CONF_OVERRIDE TMP TMP_CONF
}

# Run do_trust_anchor in a subshell so a `return`/`exit` can't kill the runner
# and each invocation re-sources against the current FORGE_CONF_OVERRIDE.
run_anchor() {
  ( set +e; source "$FORGE_CONTEXT"; do_trust_anchor )
}

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then echo "  ✓ $name"; PASS=$((PASS+1));
  else echo "  ✗ $name — expected '$expected', got '$actual'"; FAIL=$((FAIL+1)); fi
}

echo "Check 1 — VAULT_PATH + single REPO_ROOTS sharing a parent → common parent"
setup
mkdir -p "$TMP/dev/Vault" "$TMP/dev"
cat > "$TMP_CONF" <<EOF
VAULT_PATH=$TMP/dev/Vault
REPO_ROOTS=$TMP/dev
EOF
out="$(run_anchor 2>/dev/null)"; rc=$?
assert_eq "exit 0 on valid anchor" "0" "$rc"
assert_eq "stdout is the common parent dir" "$TMP/dev" "$out"
teardown

echo ""
echo "Check 2 — multiple colon-separated REPO_ROOTS → common prefix across all"
setup
mkdir -p "$TMP/root/a" "$TMP/root/b" "$TMP/root/Vault"
cat > "$TMP_CONF" <<EOF
VAULT_PATH=$TMP/root/Vault
REPO_ROOTS=$TMP/root/a:$TMP/root/b
EOF
out="$(run_anchor 2>/dev/null)"; rc=$?
assert_eq "exit 0 across multiple roots" "0" "$rc"
assert_eq "stdout is the shared root" "$TMP/root" "$out"
teardown

echo ""
echo "Check 3 — common prefix is \$HOME → rejected as too broad"
setup
cat > "$TMP_CONF" <<EOF
VAULT_PATH=$HOME/forge-anchor-test-aaa
REPO_ROOTS=$HOME/forge-anchor-test-bbb
EOF
out="$(run_anchor 2>/dev/null)"; rc=$?
if [ "$rc" -ne 0 ]; then echo "  ✓ non-zero exit on HOME prefix"; PASS=$((PASS+1));
else echo "  ✗ expected non-zero exit, got 0"; FAIL=$((FAIL+1)); fi
assert_eq "stdout empty when rejected" "" "$out"
teardown

echo ""
echo "Check 4 — common prefix doesn't exist on disk → rejected"
setup
# Note: $TMP/ghost is never created.
cat > "$TMP_CONF" <<EOF
VAULT_PATH=$TMP/ghost/Vault
REPO_ROOTS=$TMP/ghost/repo
EOF
out="$(run_anchor 2>/dev/null)"; rc=$?
if [ "$rc" -ne 0 ]; then echo "  ✓ non-zero exit on non-existent anchor"; PASS=$((PASS+1));
else echo "  ✗ expected non-zero exit, got 0"; FAIL=$((FAIL+1)); fi
assert_eq "stdout empty when rejected" "" "$out"
teardown

echo ""
echo "Check 5 — divergent sibling dirs (different components) → trims to real parent"
setup
# 'foo' vs 'foobar' share the char prefix 'foo' but are distinct components —
# the common *directory* prefix must trim back to their shared parent.
mkdir -p "$TMP/ws/foo" "$TMP/ws/foobar"
cat > "$TMP_CONF" <<EOF
VAULT_PATH=$TMP/ws/foo
REPO_ROOTS=$TMP/ws/foobar
EOF
out="$(run_anchor 2>/dev/null)"; rc=$?
assert_eq "exit 0" "0" "$rc"
assert_eq "trims at component boundary, not char prefix" "$TMP/ws" "$out"
teardown

echo ""
echo "── Total: $PASS pass, $FAIL fail ──"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
