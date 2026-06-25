#!/usr/bin/env bash
# Tests forge-context.sh update-backlog-row (Tier 1 vault-write subcommand).
#
# Behavior under test:
#  - Status-only update → Status changed, Notes preserved
#  - Notes-only update → Notes changed, Status preserved
#  - Both → both changed
#  - Row not found → exit 2 with named error
#  - Row inside <details> NOT updated (historical entries excluded — exit 2)

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

plant_backlog() {
  cat > "$TMP/PERSO/demo/BACKLOG.md" <<'EOF'
# demo — Backlog

**Updated:** 2026-06-08 09:00 CEST • **Active:** 3 rows • **Dormant:** 0 • **Latest:** stub.

## Hot

| Task | Effort | Impact | Status | Notes |
|------|:--:|:--:|------|-------|
| [[2026-06-08-target-row]] | M | H | open | original notes here |
| [[2026-06-08-other-one]] | S | M | open | other notes |
| [[2026-06-07-other-two]] | L | L | open | yet more notes |

<details>
<summary><b>Recently shipped</b></summary>

> **Shipped 2026-06-05:**
> - [[2026-06-04-history-entry]] this is in a history block, not the active table.

| Task | Effort | Impact | Status | Notes |
|------|:--:|:--:|------|-------|
| [[2026-06-04-history-entry]] | S | M | shipped | historical row inside details |

</details>
EOF
}

# ── Check 1 — status-only update ────────────────────────────────────────
echo "Check 1 — status-only update"
setup
plant_backlog
out=$("$FORGE_CONTEXT" update-backlog-row --task "2026-06-08-target-row" --status "underway" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && { echo "  ✓ exit 0"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (out: $out)"; FAIL=$((FAIL+1)); }
target_line=$(grep '\[\[2026-06-08-target-row\]\]' "$TMP/PERSO/demo/BACKLOG.md")
echo "$target_line" | grep -q "🟢<br>active" \
  && { echo "  ✓ status updated to active glyph"; PASS=$((PASS+1)); } \
  || { echo "  ✗ status not updated (got: $target_line)"; FAIL=$((FAIL+1)); }
echo "$target_line" | grep -q "original notes here" \
  && { echo "  ✓ notes preserved"; PASS=$((PASS+1)); } \
  || { echo "  ✗ notes lost (got: $target_line)"; FAIL=$((FAIL+1)); }
# Sibling rows untouched
grep -q '| \[\[2026-06-08-other-one\]\] | S | M | open | other notes |' "$TMP/PERSO/demo/BACKLOG.md" \
  && { echo "  ✓ sibling row untouched"; PASS=$((PASS+1)); } \
  || { echo "  ✗ sibling row mutated"; FAIL=$((FAIL+1)); }
teardown

# ── Check 2 — notes-only update ─────────────────────────────────────────
echo ""
echo "Check 2 — notes-only update"
setup
plant_backlog
"$FORGE_CONTEXT" update-backlog-row --task "2026-06-08-target-row" --notes "fresh notes after work" >/dev/null 2>&1
target_line=$(grep '\[\[2026-06-08-target-row\]\]' "$TMP/PERSO/demo/BACKLOG.md")
echo "$target_line" | grep -q "fresh notes after work" \
  && { echo "  ✓ notes updated"; PASS=$((PASS+1)); } \
  || { echo "  ✗ notes not updated (got: $target_line)"; FAIL=$((FAIL+1)); }
echo "$target_line" | grep -q " open " \
  && { echo "  ✓ status preserved (still 'open')"; PASS=$((PASS+1)); } \
  || { echo "  ✗ status mutated unexpectedly"; FAIL=$((FAIL+1)); }
teardown

# ── Check 3 — both status and notes ─────────────────────────────────────
echo ""
echo "Check 3 — both status and notes updated"
setup
plant_backlog
"$FORGE_CONTEXT" update-backlog-row \
  --task "2026-06-08-target-row" \
  --status "blocked" \
  --notes "PR #99 merged — closes this." >/dev/null 2>&1
target_line=$(grep '\[\[2026-06-08-target-row\]\]' "$TMP/PERSO/demo/BACKLOG.md")
echo "$target_line" | grep -q "🔴<br>blocked" \
  && { echo "  ✓ status = blocked glyph"; PASS=$((PASS+1)); } \
  || { echo "  ✗ status not updated"; FAIL=$((FAIL+1)); }
echo "$target_line" | grep -q "PR #99 merged" \
  && { echo "  ✓ notes updated to PR #99 line"; PASS=$((PASS+1)); } \
  || { echo "  ✗ notes not updated (got: $target_line)"; FAIL=$((FAIL+1)); }
echo "$target_line" | grep -q " M " \
  && { echo "  ✓ Effort column preserved"; PASS=$((PASS+1)); } \
  || { echo "  ✗ Effort column lost"; FAIL=$((FAIL+1)); }
echo "$target_line" | grep -q " H " \
  && { echo "  ✓ Impact column preserved"; PASS=$((PASS+1)); } \
  || { echo "  ✗ Impact column lost"; FAIL=$((FAIL+1)); }
teardown

# ── Check 4 — row not found → exit 2 ────────────────────────────────────
echo ""
echo "Check 4 — row not found → exit 2"
setup
plant_backlog
out=$("$FORGE_CONTEXT" update-backlog-row --task "9999-99-99-nonexistent" --status "blocked" 2>&1)
rc=$?
[ "$rc" -eq 2 ] && { echo "  ✓ exit 2 on missing row"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (expected 2)"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "no active row found" \
  && { echo "  ✓ named-error explains the miss"; PASS=$((PASS+1)); } \
  || { echo "  ✗ named-error missing (got: $out)"; FAIL=$((FAIL+1)); }
teardown

# ── Check 5 — row inside <details> NOT updated (history excluded) ───────
echo ""
echo "Check 5 — historical row inside <details> NOT matched"
setup
plant_backlog
out=$("$FORGE_CONTEXT" update-backlog-row --task "2026-06-04-history-entry" --status "blocked" --notes "no-op" 2>&1)
rc=$?
[ "$rc" -eq 2 ] && { echo "  ✓ exit 2 (history-block row not matched)"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (history-block row was mutated!)"; FAIL=$((FAIL+1)); }
# Sanity: confirm the history-block row is still intact, unmutated.
grep -q '| \[\[2026-06-04-history-entry\]\] | S | M | shipped | historical row inside details |' "$TMP/PERSO/demo/BACKLOG.md" \
  && { echo "  ✓ historical row content preserved"; PASS=$((PASS+1)); } \
  || { echo "  ✗ historical row mutated by Tier 1 update (bug!)"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "no active row found" \
  && { echo "  ✓ error message clarifies <details> exclusion"; PASS=$((PASS+1)); } \
  || { echo "  ✗ error wording missing"; FAIL=$((FAIL+1)); }
teardown

# ── Check 6 — missing required args ─────────────────────────────────────
echo ""
echo "Check 6 — missing required args"
setup
plant_backlog
out=$("$FORGE_CONTEXT" update-backlog-row --status "shipped" 2>&1)
rc=$?
[ "$rc" -eq 2 ] && { echo "  ✓ missing --task → exit 2"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc"; FAIL=$((FAIL+1)); }
out=$("$FORGE_CONTEXT" update-backlog-row --task "2026-06-08-target-row" 2>&1)
rc=$?
[ "$rc" -eq 2 ] && { echo "  ✓ missing both --status and --notes → exit 2"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (expected 2 — no fields to change)"; FAIL=$((FAIL+1)); }
teardown

echo ""; echo "Check 7 — effort/impact render via flags"
setup; plant_backlog
"$FORGE_CONTEXT" update-backlog-row --task "2026-06-08-target-row" --effort "L" --impact "L" >/dev/null 2>&1
tl=$(grep '\[\[2026-06-08-target-row\]\]' "$TMP/PERSO/demo/BACKLOG.md")
echo "$tl" | grep -q "🟦🟦🟦<br>L" && { echo "  ✓ effort rendered"; PASS=$((PASS+1)); } || { echo "  ✗ effort (got: $tl)"; FAIL=$((FAIL+1)); }
echo "$tl" | grep -q "🟪<br>L" && { echo "  ✓ impact rendered"; PASS=$((PASS+1)); } || { echo "  ✗ impact (got: $tl)"; FAIL=$((FAIL+1)); }
teardown

echo ""; echo "Check 8 — effort-only update preserves impact"
setup; plant_backlog
"$FORGE_CONTEXT" update-backlog-row --task "2026-06-08-target-row" --effort "L" >/dev/null 2>&1
tl=$(grep '\[\[2026-06-08-target-row\]\]' "$TMP/PERSO/demo/BACKLOG.md")
echo "$tl" | grep -q "🟦🟦🟦<br>L" && { echo "  ✓ effort rendered"; PASS=$((PASS+1)); } || { echo "  ✗ effort (got: $tl)"; FAIL=$((FAIL+1)); }
echo "$tl" | grep -q "| H |" && { echo "  ✓ impact preserved (raw H)"; PASS=$((PASS+1)); } || { echo "  ✗ impact not preserved (got: $tl)"; FAIL=$((FAIL+1)); }
teardown
echo ""; echo "Check 9 — impact-only update preserves effort"
setup; plant_backlog
"$FORGE_CONTEXT" update-backlog-row --task "2026-06-08-target-row" --impact "H" >/dev/null 2>&1
tl=$(grep '\[\[2026-06-08-target-row\]\]' "$TMP/PERSO/demo/BACKLOG.md")
echo "$tl" | grep -q "🟪🟪🟪<br>H" && { echo "  ✓ impact rendered"; PASS=$((PASS+1)); } || { echo "  ✗ impact (got: $tl)"; FAIL=$((FAIL+1)); }
echo "$tl" | grep -q "| M |" && { echo "  ✓ effort preserved (raw M)"; PASS=$((PASS+1)); } || { echo "  ✗ effort not preserved (got: $tl)"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "── Total: $PASS pass, $FAIL fail ──"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
