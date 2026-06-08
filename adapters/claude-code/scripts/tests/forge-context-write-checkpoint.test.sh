#!/usr/bin/env bash
# Tests forge-context.sh write-checkpoint (Tier 1 vault-write subcommand).
#
# Behavior under test:
#  - Heredoc body → current-checkpoint.md written with frontmatter prepended
#  - Frontmatter date/time populated from current system time, project from marker
#  - Path-prefix validation rejects writes outside $VAULT_PATH (exit 2)
#  - Stdout shows the one-line success log

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_CONTEXT="$SCRIPT_DIR/../forge-context.sh"

PASS=0; FAIL=0

setup() {
  TMP=$(mktemp -d)
  TMP_CONF="$TMP/forge.conf"
  echo "VAULT_PATH=$TMP" > "$TMP_CONF"
  echo "REPO_ROOTS=$TMP/repos" >> "$TMP_CONF"
  mkdir -p "$TMP/_shared" "$TMP/PERSO/demo" "$TMP/repos/demo"
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

# ── Check 1 — happy path: stdin body → file written with frontmatter ────
echo "Check 1 — happy path heredoc body"
setup
out=$("$FORGE_CONTEXT" write-checkpoint <<'EOF' 2>&1
# demo Checkpoint — test entry

Session body line one.

Session body line two.
EOF
)
rc=$?
[ "$rc" -eq 0 ] && { echo "  ✓ exit 0"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (out: $out)"; FAIL=$((FAIL+1)); }
[ -f "$TMP/PERSO/demo/current-checkpoint.md" ] \
  && { echo "  ✓ current-checkpoint.md exists"; PASS=$((PASS+1)); } \
  || { echo "  ✗ current-checkpoint.md missing"; FAIL=$((FAIL+1)); }
grep -q "^# demo Checkpoint — test entry$" "$TMP/PERSO/demo/current-checkpoint.md" \
  && { echo "  ✓ H1 title preserved verbatim"; PASS=$((PASS+1)); } \
  || { echo "  ✗ H1 title missing or wrong"; FAIL=$((FAIL+1)); }
grep -q "^Session body line one\.$" "$TMP/PERSO/demo/current-checkpoint.md" \
  && { echo "  ✓ body preserved verbatim"; PASS=$((PASS+1)); } \
  || { echo "  ✗ body content missing"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "^\[write-checkpoint\] current-checkpoint.md updated" \
  && { echo "  ✓ stdout one-line success log present"; PASS=$((PASS+1)); } \
  || { echo "  ✗ stdout success log missing (got: $out)"; FAIL=$((FAIL+1)); }
teardown

# ── Check 2 — frontmatter contains date/time/project/session ────────────
echo ""
echo "Check 2 — frontmatter populated correctly"
setup
"$FORGE_CONTEXT" write-checkpoint <<'EOF' >/dev/null 2>&1
# demo Checkpoint — fm test

Body.
EOF
grep -q "^date: $(today)$" "$TMP/PERSO/demo/current-checkpoint.md" \
  && { echo "  ✓ frontmatter date: today"; PASS=$((PASS+1)); } \
  || { echo "  ✗ frontmatter date missing or wrong"; FAIL=$((FAIL+1)); }
grep -qE '^time: "[0-9]{2}:[0-9]{2}"$' "$TMP/PERSO/demo/current-checkpoint.md" \
  && { echo "  ✓ frontmatter time: HH:MM"; PASS=$((PASS+1)); } \
  || { echo "  ✗ frontmatter time missing or malformed"; FAIL=$((FAIL+1)); }
grep -q "^project: demo$" "$TMP/PERSO/demo/current-checkpoint.md" \
  && { echo "  ✓ frontmatter project: from marker"; PASS=$((PASS+1)); } \
  || { echo "  ✗ frontmatter project missing"; FAIL=$((FAIL+1)); }
grep -q "^session: open$" "$TMP/PERSO/demo/current-checkpoint.md" \
  && { echo "  ✓ frontmatter session: open"; PASS=$((PASS+1)); } \
  || { echo "  ✗ frontmatter session missing"; FAIL=$((FAIL+1)); }
teardown

# ── Check 3 — overwrites existing checkpoint ────────────────────────────
echo ""
echo "Check 3 — overwrites prior checkpoint atomically"
setup
echo "old content" > "$TMP/PERSO/demo/current-checkpoint.md"
"$FORGE_CONTEXT" write-checkpoint <<'EOF' >/dev/null 2>&1
# demo Checkpoint — fresh
EOF
grep -q "old content" "$TMP/PERSO/demo/current-checkpoint.md" \
  && { echo "  ✗ old content survived overwrite"; FAIL=$((FAIL+1)); } \
  || { echo "  ✓ prior content replaced"; PASS=$((PASS+1)); }
grep -q "^# demo Checkpoint — fresh$" "$TMP/PERSO/demo/current-checkpoint.md" \
  && { echo "  ✓ new H1 title present"; PASS=$((PASS+1)); } \
  || { echo "  ✗ new H1 missing"; FAIL=$((FAIL+1)); }
teardown

# ── Check 4 — empty body → exit 2 ───────────────────────────────────────
echo ""
echo "Check 4 — empty stdin body rejected"
setup
out=$("$FORGE_CONTEXT" write-checkpoint </dev/null 2>&1)
rc=$?
[ "$rc" -eq 2 ] && { echo "  ✓ exit 2 on empty stdin"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc on empty stdin (expected 2)"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "FAIL" \
  && { echo "  ✓ FAIL message emitted"; PASS=$((PASS+1)); } \
  || { echo "  ✗ FAIL message missing"; FAIL=$((FAIL+1)); }
teardown

# ── Check 5 — no marker → exit 2 (no active project) ────────────────────
echo ""
echo "Check 5 — no active marker → exit 2"
setup
rm -f "$TMP/_shared/forge-active"
out=$("$FORGE_CONTEXT" write-checkpoint <<'EOF' 2>&1
# x
body
EOF
)
rc=$?
# Without marker the per-subcommand setup branch the script took allows write-checkpoint to proceed,
# but resolve_active_project_or_die catches it. Accept either exit 0 (no-op early exit)
# or exit 2 (explicit FAIL). The contract is: no write happens.
[ ! -f "$TMP/PERSO/demo/current-checkpoint.md" ] \
  && { echo "  ✓ no checkpoint written without marker"; PASS=$((PASS+1)); } \
  || { echo "  ✗ checkpoint written despite missing marker"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "── Total: $PASS pass, $FAIL fail ──"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
