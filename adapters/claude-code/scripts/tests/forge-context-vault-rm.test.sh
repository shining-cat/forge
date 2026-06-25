#!/usr/bin/env bash
# Tests forge-context.sh vault-rm (guarded under-vault deletion subcommand).
#
# Behavior under test:
#  - Removes files/dirs that resolve to a real path strictly UNDER VAULT_PATH.
#  - Refuses (exit 2, target untouched) for:
#      * paths outside the vault
#      * the vault root itself
#      * any dir that IS or CONTAINS a .git repo
#      * nonexistent paths
#      * symlinks (inside the vault) whose real target is outside the vault
#  - Routed under the normal config gate (needs VAULT_PATH), but no marker /
#    active-project required.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_CONTEXT="$SCRIPT_DIR/../forge-context.sh"

PASS=0; FAIL=0

setup() {
  TMP=$(mktemp -d)
  OUTSIDE=$(mktemp -d)          # a separate tree, NOT under the vault
  TMP_CONF="$TMP/forge.conf"
  echo "VAULT_PATH=$TMP" > "$TMP_CONF"
  echo "REPO_ROOTS=$TMP/repos" >> "$TMP_CONF"
  mkdir -p "$TMP/_shared" "$TMP/PERSO/demo/tasks/open" "$TMP/repos/demo"
  cat > "$TMP/_shared/forge-active" <<'EOF'
{"session_id":"test-session","project":"demo","started_at":"2026-06-08T10:00:00+0200","tmux_pane":null}
EOF
  export FORGE_CONF_OVERRIDE="$TMP_CONF"
  export CLAUDE_CODE_SESSION_ID="test-session"
}

teardown() {
  rm -rf "$TMP" "$OUTSIDE"
  unset FORGE_CONF_OVERRIDE CLAUDE_CODE_SESSION_ID TMP OUTSIDE TMP_CONF
}

# ── Check 1 — happy path: a file under the vault is removed ──────────────
echo "Check 1 — file under vault removed"
setup
F="$TMP/PERSO/demo/tasks/open/disposable.md"
echo "junk" > "$F"
out=$("$FORGE_CONTEXT" vault-rm "$F" 2>&1); rc=$?
[ "$rc" -eq 0 ] && { echo "  ✓ exit 0"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (out: $out)"; FAIL=$((FAIL+1)); }
[ ! -e "$F" ] && { echo "  ✓ file removed"; PASS=$((PASS+1)); } \
  || { echo "  ✗ file still present"; FAIL=$((FAIL+1)); }
teardown

# ── Check 2 — happy path: an empty subdir under vault removed ────────────
echo ""
echo "Check 2 — empty subdir under vault removed"
setup
D="$TMP/PERSO/demo/tasks/open/disposable-dir"
mkdir -p "$D"
out=$("$FORGE_CONTEXT" vault-rm "$D" 2>&1); rc=$?
[ "$rc" -eq 0 ] && { echo "  ✓ exit 0"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (out: $out)"; FAIL=$((FAIL+1)); }
[ ! -e "$D" ] && { echo "  ✓ dir removed"; PASS=$((PASS+1)); } \
  || { echo "  ✗ dir still present"; FAIL=$((FAIL+1)); }
teardown

# ── Check 3 — reject: path OUTSIDE the vault ────────────────────────────
echo ""
echo "Check 3 — path outside vault rejected"
setup
F="$OUTSIDE/keepme.txt"
echo "important" > "$F"
out=$("$FORGE_CONTEXT" vault-rm "$F" 2>&1); rc=$?
[ "$rc" -eq 2 ] && { echo "  ✓ exit 2"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (out: $out)"; FAIL=$((FAIL+1)); }
[ -e "$F" ] && { echo "  ✓ outside file untouched"; PASS=$((PASS+1)); } \
  || { echo "  ✗ outside file was removed!"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "not under VAULT_PATH" \
  && { echo "  ✓ message names containment"; PASS=$((PASS+1)); } \
  || { echo "  ✗ message missing (got: $out)"; FAIL=$((FAIL+1)); }
teardown

# ── Check 4 — reject: vault root itself ─────────────────────────────────
echo ""
echo "Check 4 — vault root rejected"
setup
out=$("$FORGE_CONTEXT" vault-rm "$TMP" 2>&1); rc=$?
[ "$rc" -eq 2 ] && { echo "  ✓ exit 2"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (out: $out)"; FAIL=$((FAIL+1)); }
[ -d "$TMP" ] && { echo "  ✓ vault root untouched"; PASS=$((PASS+1)); } \
  || { echo "  ✗ vault root was removed!"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "vault root" \
  && { echo "  ✓ message names vault root"; PASS=$((PASS+1)); } \
  || { echo "  ✗ message missing (got: $out)"; FAIL=$((FAIL+1)); }
teardown

# ── Check 5 — reject: directory containing a .git dir ───────────────────
echo ""
echo "Check 5 — dir containing .git rejected"
setup
D="$TMP/PERSO/demo/nested-repo"
mkdir -p "$D/sub/.git"
out=$("$FORGE_CONTEXT" vault-rm "$D" 2>&1); rc=$?
[ "$rc" -eq 2 ] && { echo "  ✓ exit 2"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (out: $out)"; FAIL=$((FAIL+1)); }
[ -d "$D" ] && { echo "  ✓ repo dir untouched"; PASS=$((PASS+1)); } \
  || { echo "  ✗ repo dir was removed!"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q ".git repo" \
  && { echo "  ✓ message names repo guard"; PASS=$((PASS+1)); } \
  || { echo "  ✗ message missing (got: $out)"; FAIL=$((FAIL+1)); }
teardown

# ── Check 6 — reject: nonexistent path ──────────────────────────────────
echo ""
echo "Check 6 — nonexistent path rejected"
setup
out=$("$FORGE_CONTEXT" vault-rm "$TMP/PERSO/demo/does-not-exist" 2>&1); rc=$?
[ "$rc" -eq 2 ] && { echo "  ✓ exit 2"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (out: $out)"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "does not exist" \
  && { echo "  ✓ message names existence"; PASS=$((PASS+1)); } \
  || { echo "  ✗ message missing (got: $out)"; FAIL=$((FAIL+1)); }
teardown

# ── Check 7 — reject: symlink inside vault pointing OUTSIDE ──────────────
echo ""
echo "Check 7 — symlink escape rejected, real target preserved"
setup
REAL="$OUTSIDE/real-secret.txt"
echo "do not delete" > "$REAL"
LINK="$TMP/PERSO/demo/escape-link"
ln -s "$REAL" "$LINK"
out=$("$FORGE_CONTEXT" vault-rm "$LINK" 2>&1); rc=$?
[ "$rc" -eq 2 ] && { echo "  ✓ exit 2"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (out: $out)"; FAIL=$((FAIL+1)); }
[ -e "$REAL" ] && { echo "  ✓ real (outside) target untouched"; PASS=$((PASS+1)); } \
  || { echo "  ✗ real target was removed via symlink!"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "not under VAULT_PATH" \
  && { echo "  ✓ message names containment"; PASS=$((PASS+1)); } \
  || { echo "  ✗ message missing (got: $out)"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "── Total: $PASS pass, $FAIL fail ──"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
