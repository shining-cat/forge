#!/usr/bin/env bash
# Tests forge-context.sh new-task (Tier 1 vault-write subcommand).
#
# Behavior under test:
#  - Minimal args (slug + title) → file with default frontmatter
#  - All-args version → all fields populated
#  - Stdin body preserved verbatim
#  - Refuse-overwrite case (exit 2, file unchanged)
#  - Missing required args (exit 2 with named error)

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_CONTEXT="$SCRIPT_DIR/../forge-context.sh"

PASS=0; FAIL=0

setup() {
  TMP=$(mktemp -d)
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
  rm -rf "$TMP"
  unset FORGE_CONF_OVERRIDE CLAUDE_CODE_SESSION_ID TMP TMP_CONF
}

today() { date +%Y-%m-%d; }

# ── Check 1 — minimal args (slug + title, no stdin) ─────────────────────
echo "Check 1 — minimal args → defaults populated"
setup
out=$("$FORGE_CONTEXT" new-task --slug "2026-06-09-minimal" --title "Minimal title" </dev/null 2>&1)
rc=$?
[ "$rc" -eq 0 ] && { echo "  ✓ exit 0"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (out: $out)"; FAIL=$((FAIL+1)); }
F="$TMP/PERSO/demo/tasks/open/2026-06-09-minimal.md"
[ -f "$F" ] && { echo "  ✓ file created"; PASS=$((PASS+1)); } \
  || { echo "  ✗ file not created"; FAIL=$((FAIL+1)); }
grep -q "^created: $(today)$" "$F" \
  && { echo "  ✓ frontmatter created: today"; PASS=$((PASS+1)); } \
  || { echo "  ✗ created: missing"; FAIL=$((FAIL+1)); }
grep -q "^updated: $(today)$" "$F" \
  && { echo "  ✓ frontmatter updated: today"; PASS=$((PASS+1)); } \
  || { echo "  ✗ updated: missing"; FAIL=$((FAIL+1)); }
grep -q "^project: demo$" "$F" \
  && { echo "  ✓ frontmatter project: from marker"; PASS=$((PASS+1)); } \
  || { echo "  ✗ project: missing"; FAIL=$((FAIL+1)); }
grep -q "^status: open$" "$F" \
  && { echo "  ✓ frontmatter status default = open"; PASS=$((PASS+1)); } \
  || { echo "  ✗ status default missing"; FAIL=$((FAIL+1)); }
grep -q "^# Minimal title$" "$F" \
  && { echo "  ✓ H1 title rendered"; PASS=$((PASS+1)); } \
  || { echo "  ✗ H1 missing"; FAIL=$((FAIL+1)); }
grep -q "^## What / Why$" "$F" \
  && { echo "  ✓ default body skeleton present"; PASS=$((PASS+1)); } \
  || { echo "  ✗ default body skeleton missing"; FAIL=$((FAIL+1)); }
teardown

# ── Check 2 — all args populated ────────────────────────────────────────
echo ""
echo "Check 2 — all args populated"
setup
"$FORGE_CONTEXT" new-task \
  --slug "2026-06-09-full" \
  --title "Full title here" \
  --status "designed" \
  --effort "M" \
  --impact "H" \
  --priority "P1" \
  --tags "alpha,beta,gamma" </dev/null >/dev/null 2>&1
F="$TMP/PERSO/demo/tasks/open/2026-06-09-full.md"
grep -q "^status: designed$" "$F" \
  && { echo "  ✓ status = designed"; PASS=$((PASS+1)); } \
  || { echo "  ✗ status not set"; FAIL=$((FAIL+1)); }
grep -q "^effort: M$" "$F" \
  && { echo "  ✓ effort = M"; PASS=$((PASS+1)); } \
  || { echo "  ✗ effort not set"; FAIL=$((FAIL+1)); }
grep -q "^impact: H$" "$F" \
  && { echo "  ✓ impact = H"; PASS=$((PASS+1)); } \
  || { echo "  ✗ impact not set"; FAIL=$((FAIL+1)); }
grep -q "^priority: P1$" "$F" \
  && { echo "  ✓ priority = P1"; PASS=$((PASS+1)); } \
  || { echo "  ✗ priority not set"; FAIL=$((FAIL+1)); }
grep -q "^tags: \[alpha, beta, gamma\]$" "$F" \
  && { echo "  ✓ tags rendered as YAML list"; PASS=$((PASS+1)); } \
  || { echo "  ✗ tags malformed (got: $(grep '^tags:' "$F"))"; FAIL=$((FAIL+1)); }
teardown

# ── Check 3 — stdin body preserved verbatim ─────────────────────────────
echo ""
echo "Check 3 — stdin body preserved verbatim"
setup
"$FORGE_CONTEXT" new-task --slug "2026-06-09-stdin" --title "Stdin body" <<'EOF' >/dev/null 2>&1
## What / Why

Custom body line one.

Custom body line two.

## Plan

Plan stub.
EOF
F="$TMP/PERSO/demo/tasks/open/2026-06-09-stdin.md"
grep -q "^Custom body line one\.$" "$F" \
  && { echo "  ✓ custom body line preserved"; PASS=$((PASS+1)); } \
  || { echo "  ✗ custom body missing"; FAIL=$((FAIL+1)); }
grep -q "^Plan stub\.$" "$F" \
  && { echo "  ✓ custom Plan section preserved"; PASS=$((PASS+1)); } \
  || { echo "  ✗ Plan section missing"; FAIL=$((FAIL+1)); }
teardown

# ── Check 4 — refuse to overwrite existing file ─────────────────────────
echo ""
echo "Check 4 — refuse to overwrite existing file"
setup
F="$TMP/PERSO/demo/tasks/open/2026-06-09-existing.md"
echo "ORIGINAL CONTENT" > "$F"
out=$("$FORGE_CONTEXT" new-task --slug "2026-06-09-existing" --title "Would-be overwrite" </dev/null 2>&1)
rc=$?
[ "$rc" -eq 2 ] && { echo "  ✓ exit 2 on overwrite attempt"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc on overwrite (expected 2)"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "already exists" \
  && { echo "  ✓ FAIL message mentions existence"; PASS=$((PASS+1)); } \
  || { echo "  ✗ FAIL message missing 'already exists' (got: $out)"; FAIL=$((FAIL+1)); }
grep -q "ORIGINAL CONTENT" "$F" \
  && { echo "  ✓ original file untouched"; PASS=$((PASS+1)); } \
  || { echo "  ✗ original file mutated"; FAIL=$((FAIL+1)); }
teardown

# ── Check 5 — missing required args ─────────────────────────────────────
echo ""
echo "Check 5 — missing required args"
setup
out=$("$FORGE_CONTEXT" new-task --title "no-slug-here" </dev/null 2>&1)
rc=$?
[ "$rc" -eq 2 ] && { echo "  ✓ missing --slug → exit 2"; PASS=$((PASS+1)); } \
  || { echo "  ✗ missing --slug exit $rc"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "slug required" \
  && { echo "  ✓ FAIL message names --slug"; PASS=$((PASS+1)); } \
  || { echo "  ✗ slug-required message missing"; FAIL=$((FAIL+1)); }

out=$("$FORGE_CONTEXT" new-task --slug "2026-06-09-no-title" </dev/null 2>&1)
rc=$?
[ "$rc" -eq 2 ] && { echo "  ✓ missing --title → exit 2"; PASS=$((PASS+1)); } \
  || { echo "  ✗ missing --title exit $rc"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "title required" \
  && { echo "  ✓ FAIL message names --title"; PASS=$((PASS+1)); } \
  || { echo "  ✗ title-required message missing"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "── Total: $PASS pass, $FAIL fail ──"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
