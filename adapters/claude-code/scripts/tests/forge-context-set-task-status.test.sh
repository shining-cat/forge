#!/usr/bin/env bash
# Tests forge-context.sh set-task-status (Tier 1 vault-write subcommand).
#
# Behavior under test:
#  - Status update → frontmatter status: + updated: refreshed
#  - --add-progress appends a timestamped line under ## Progress
#  - File not found → exit 2 with named error
#  - ## Progress section missing → status flips, progress entry skipped with WARN

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_CONTEXT="$SCRIPT_DIR/../forge-context.sh"

PASS=0; FAIL=0

setup() {
  TMP=$(mktemp -d)
  TMP_CONF="$TMP/forge.conf"
  echo "VAULT_PATH=$TMP" > "$TMP_CONF"
  echo "REPO_ROOTS=$TMP/repos" >> "$TMP_CONF"
  mkdir -p "$TMP/_shared" "$TMP/PERSO/demo/tasks/open" "$TMP/PERSO/demo/tasks/resolved" "$TMP/repos/demo"
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

plant_task_with_progress() {
  local path="$1"
  cat > "$path" <<'EOF'
---
created: 2026-06-01
updated: 2026-06-01
project: demo
type: task
status: open
tags: []
---

# Test task

## What / Why

Body.

## Progress

- 2026-06-01 — initial filing.

## Resolution

EOF
}

plant_task_no_progress() {
  local path="$1"
  cat > "$path" <<'EOF'
---
created: 2026-06-01
updated: 2026-06-01
project: demo
type: task
status: open
tags: []
---

# Test task

## What / Why

Body.

## Resolution

EOF
}

# ── Check 1 — basic status update ───────────────────────────────────────
echo "Check 1 — basic status update"
setup
F="$TMP/PERSO/demo/tasks/open/2026-06-08-flip.md"
plant_task_with_progress "$F"
out=$("$FORGE_CONTEXT" set-task-status --slug "2026-06-08-flip" --status "in-progress" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && { echo "  ✓ exit 0"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (out: $out)"; FAIL=$((FAIL+1)); }
grep -q "^status: in-progress$" "$F" \
  && { echo "  ✓ status flipped to in-progress"; PASS=$((PASS+1)); } \
  || { echo "  ✗ status not flipped (got: $(grep '^status:' "$F"))"; FAIL=$((FAIL+1)); }
grep -q "^updated: $(today)$" "$F" \
  && { echo "  ✓ updated: refreshed to today"; PASS=$((PASS+1)); } \
  || { echo "  ✗ updated: not refreshed"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "^\[set-task-status\]" \
  && { echo "  ✓ stdout success line present"; PASS=$((PASS+1)); } \
  || { echo "  ✗ stdout success line missing"; FAIL=$((FAIL+1)); }
teardown

# ── Check 2 — --add-progress appends new line under ## Progress ─────────
echo ""
echo "Check 2 — --add-progress inserts line"
setup
F="$TMP/PERSO/demo/tasks/open/2026-06-08-prog.md"
plant_task_with_progress "$F"
out=$("$FORGE_CONTEXT" set-task-status --slug "2026-06-08-prog" --status "in-progress" --add-progress "Started experimental branch." 2>&1)
rc=$?
[ "$rc" -eq 0 ] && { echo "  ✓ exit 0"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc"; FAIL=$((FAIL+1)); }
grep -qE "^- $(today) [0-9]{2}:[0-9]{2} — Started experimental branch\.$" "$F" \
  && { echo "  ✓ progress line appended with timestamp"; PASS=$((PASS+1)); } \
  || { echo "  ✗ progress line missing"; FAIL=$((FAIL+1)); }
# Verify it landed AFTER the existing line under ## Progress, not elsewhere.
grep -q "^- 2026-06-01 — initial filing\.$" "$F" \
  && { echo "  ✓ existing progress line preserved"; PASS=$((PASS+1)); } \
  || { echo "  ✗ existing line lost"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "progress appended" \
  && { echo "  ✓ stdout reports progress appended"; PASS=$((PASS+1)); } \
  || { echo "  ✗ stdout missing progress note"; FAIL=$((FAIL+1)); }
teardown

# ── Check 3 — file not found → exit 2 ────────────────────────────────────
echo ""
echo "Check 3 — file not found → exit 2"
setup
out=$("$FORGE_CONTEXT" set-task-status --slug "2026-06-08-nope" --status "resolved" 2>&1)
rc=$?
[ "$rc" -eq 2 ] && { echo "  ✓ exit 2 on missing file"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (expected 2)"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "no task file found" \
  && { echo "  ✓ FAIL message names the gap"; PASS=$((PASS+1)); } \
  || { echo "  ✗ named-error missing (got: $out)"; FAIL=$((FAIL+1)); }
teardown

# ── Check 4 — ## Progress missing → flip OK, WARN about skip ────────────
echo ""
echo "Check 4 — ## Progress section missing"
setup
F="$TMP/PERSO/demo/tasks/open/2026-06-08-noprog.md"
plant_task_no_progress "$F"
out=$("$FORGE_CONTEXT" set-task-status --slug "2026-06-08-noprog" --status "blocked" --add-progress "tried to add but no section" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && { echo "  ✓ exit 0 (status flip still succeeds)"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (expected 0)"; FAIL=$((FAIL+1)); }
grep -q "^status: blocked$" "$F" \
  && { echo "  ✓ status flipped despite no Progress section"; PASS=$((PASS+1)); } \
  || { echo "  ✗ status not flipped"; FAIL=$((FAIL+1)); }
grep -q "tried to add but no section" "$F" \
  && { echo "  ✗ progress line leaked into file"; FAIL=$((FAIL+1)); } \
  || { echo "  ✓ progress line NOT added (no section)"; PASS=$((PASS+1)); }
echo "$out" | grep -q "WARN" \
  && { echo "  ✓ WARN emitted to stderr"; PASS=$((PASS+1)); } \
  || { echo "  ✗ WARN missing (got: $out)"; FAIL=$((FAIL+1)); }
teardown

# ── Check 5 — file in tasks/resolved/ also searchable ───────────────────
echo ""
echo "Check 5 — tasks/resolved/ also searched"
setup
F="$TMP/PERSO/demo/tasks/resolved/2026-06-08-already-done.md"
plant_task_with_progress "$F"
out=$("$FORGE_CONTEXT" set-task-status --slug "2026-06-08-already-done" --status "resolved" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && { echo "  ✓ exit 0"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc"; FAIL=$((FAIL+1)); }
grep -q "^status: resolved$" "$F" \
  && { echo "  ✓ resolved-folder task updated in place"; PASS=$((PASS+1)); } \
  || { echo "  ✗ resolved-folder file not updated"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "── Total: $PASS pass, $FAIL fail ──"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
