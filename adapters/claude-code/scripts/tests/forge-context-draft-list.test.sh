#!/usr/bin/env bash
# Tests do_draft_list (drafts enumeration for /forge-weekly triage).
#
# Regression focus: a draft file with NO `# ` H1 heading used to abort the
# whole function. `title=$(grep -m1 '^# ' … | sed …)` exits 1 on no-match,
# and under `set -euo pipefail` that 1 propagates and kills do_draft_list
# before it can printf the row — so draft-list exited 1 with no output even
# though a draft existed (task 2026-07-27-fix-draft-list-exit1).

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_CONTEXT="$SCRIPT_DIR/../forge-context.sh"

PASS=0; FAIL=0

# draft-list is a whole-vault scan with NO stdin read and NO active-project
# requirement (sibling of draft-invite-line) — so the harness deliberately
# creates no forge-active marker. If draft-list ever needs a marker to run,
# these checks catch the regression (they'd exit 0 with empty output).
setup() {
  TMP=$(mktemp -d)
  TMP_CONF="$TMP/forge.conf"
  echo "VAULT_PATH=$TMP" > "$TMP_CONF"
  echo "REPO_ROOTS=$TMP/repos" >> "$TMP_CONF"
  mkdir -p "$TMP/_shared/tasks/drafts" "$TMP/PERSO/demo/tasks/drafts"
  export FORGE_CONF_OVERRIDE="$TMP_CONF"
}

teardown() {
  rm -rf "$TMP"
  unset FORGE_CONF_OVERRIDE TMP TMP_CONF
}

# ── Check 1 — draft WITH an H1 heading lists as TSV, exit 0 ─────────────
echo "Check 1 — draft with H1 heading"
setup
cat > "$TMP/PERSO/demo/tasks/drafts/idea-one.md" <<'EOF'
---
project: PERSO/demo
type: draft
---

# A captured idea
body
EOF
out=$("$FORGE_CONTEXT" draft-list 2>&1); rc=$?
[ "$rc" -eq 0 ] \
  && { echo "  ✓ exit 0"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (expected 0)"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "A captured idea" \
  && { echo "  ✓ H1 title in output"; PASS=$((PASS+1)); } \
  || { echo "  ✗ H1 title missing"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "PERSO/demo" \
  && { echo "  ✓ project column present"; PASS=$((PASS+1)); } \
  || { echo "  ✗ project column missing"; FAIL=$((FAIL+1)); }
teardown

# ── Check 2 — draft WITHOUT an H1 heading still lists (the bug) ─────────
echo ""
echo "Check 2 — draft with NO H1 heading (regression)"
setup
cat > "$TMP/_shared/tasks/drafts/headless-draft.md" <<'EOF'
---
type: draft
---

just some captured text, no markdown heading at all
EOF
out=$("$FORGE_CONTEXT" draft-list 2>&1); rc=$?
[ "$rc" -eq 0 ] \
  && { echo "  ✓ exit 0 on headless draft"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (expected 0) — grep-no-match abort"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "headless-draft" \
  && { echo "  ✓ row emitted (filename title fallback)"; PASS=$((PASS+1)); } \
  || { echo "  ✗ no row emitted for headless draft"; FAIL=$((FAIL+1)); }
teardown

# ── Check 3 — no drafts: exit 0, empty output ──────────────────────────
echo ""
echo "Check 3 — no drafts"
setup
out=$("$FORGE_CONTEXT" draft-list 2>&1); rc=$?
[ "$rc" -eq 0 ] \
  && { echo "  ✓ exit 0"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (expected 0)"; FAIL=$((FAIL+1)); }
[ -z "$out" ] \
  && { echo "  ✓ empty output"; PASS=$((PASS+1)); } \
  || { echo "  ✗ unexpected output: $out"; FAIL=$((FAIL+1)); }
teardown

# ── Check 4 — _discarded/ grace-period subdir is skipped ───────────────
echo ""
echo "Check 4 — _discarded/ drafts skipped"
setup
mkdir -p "$TMP/_shared/tasks/drafts/_discarded"
cat > "$TMP/_shared/tasks/drafts/_discarded/old.md" <<'EOF'
---
type: draft
---
# discarded idea
EOF
out=$("$FORGE_CONTEXT" draft-list 2>&1); rc=$?
[ "$rc" -eq 0 ] \
  && { echo "  ✓ exit 0"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (expected 0)"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "discarded idea" \
  && { echo "  ✗ _discarded draft leaked into listing"; FAIL=$((FAIL+1)); } \
  || { echo "  ✓ _discarded draft skipped"; PASS=$((PASS+1)); }
teardown

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
