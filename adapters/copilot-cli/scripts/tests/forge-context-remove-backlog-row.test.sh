#!/usr/bin/env bash
# Tests forge-context.sh remove-backlog-row (Tier 1 vault-write subcommand).
#
# Motivation (2026-08-07 friction — keeper too heavy for trivial edits): removing
# a shipped row from the BACKLOG Hot table used to require dispatching a whole
# forge-keeper subagent (~8 min, 16 tool-uses for one line deletion). This is the
# silent Tier-1 path — parse --task <slug>, delete the matching active row, done.
#
# Behavior under test:
#  - Target active row removed → exit 0, row gone, siblings + header intact
#  - Row not found → exit 2 with named error
#  - Row inside <details> NOT removed (historical entries preserved — exit 2)
#  - Missing --task → exit 2

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
  export COPILOT_SESSION_ID="test-session"
}

teardown() {
  rm -rf "$TMP"
  unset FORGE_CONF_OVERRIDE COPILOT_SESSION_ID TMP TMP_CONF
}

plant_backlog() {
  cat > "$TMP/PERSO/demo/BACKLOG.md" <<'EOF'
# demo — Backlog

**Updated:** 2026-06-08 09:00 CEST • **Active:** 3 rows • **Dormant:** 0 • **Latest:** stub.

## Hot

| Task | Effort | Impact | Status | Notes |
|------|:--:|:--:|------|-------|
| [[2026-06-08-target-row]] | M | L | open | original notes here |
| [[2026-06-08-other-one]] | S | M | open | other notes |
| [[2026-06-07-other-two]] | L | S | open | yet more notes |

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

# ── Check 1 — remove target active row ──────────────────────────────────
echo "Check 1 — remove target active row"
setup
plant_backlog
out=$("$FORGE_CONTEXT" remove-backlog-row --task "2026-06-08-target-row" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && { echo "  ✓ exit 0"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (out: $out)"; FAIL=$((FAIL+1)); }
grep -q '\[\[2026-06-08-target-row\]\]' "$TMP/PERSO/demo/BACKLOG.md" \
  && { echo "  ✗ target row still present"; FAIL=$((FAIL+1)); } \
  || { echo "  ✓ target row removed"; PASS=$((PASS+1)); }
# Sibling rows untouched
grep -q '| \[\[2026-06-08-other-one\]\] | S | M | open | other notes |' "$TMP/PERSO/demo/BACKLOG.md" \
  && { echo "  ✓ sibling row 1 untouched"; PASS=$((PASS+1)); } \
  || { echo "  ✗ sibling row 1 mutated"; FAIL=$((FAIL+1)); }
grep -q '| \[\[2026-06-07-other-two\]\] | L | S | open | yet more notes |' "$TMP/PERSO/demo/BACKLOG.md" \
  && { echo "  ✓ sibling row 2 untouched"; PASS=$((PASS+1)); } \
  || { echo "  ✗ sibling row 2 mutated"; FAIL=$((FAIL+1)); }
# Header + table scaffold intact
grep -q '^## Hot' "$TMP/PERSO/demo/BACKLOG.md" \
  && { echo "  ✓ Hot header intact"; PASS=$((PASS+1)); } \
  || { echo "  ✗ Hot header lost"; FAIL=$((FAIL+1)); }
teardown

# ── Check 2 — row not found → exit 2 ────────────────────────────────────
echo ""
echo "Check 2 — row not found → exit 2"
setup
plant_backlog
out=$("$FORGE_CONTEXT" remove-backlog-row --task "9999-99-99-nonexistent" 2>&1)
rc=$?
[ "$rc" -eq 2 ] && { echo "  ✓ exit 2 on missing row"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (expected 2)"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "no active row found" \
  && { echo "  ✓ named-error explains the miss"; PASS=$((PASS+1)); } \
  || { echo "  ✗ named-error missing (got: $out)"; FAIL=$((FAIL+1)); }
teardown

# ── Check 3 — row inside <details> NOT removed (history preserved) ───────
echo ""
echo "Check 3 — historical row inside <details> NOT matched"
setup
plant_backlog
out=$("$FORGE_CONTEXT" remove-backlog-row --task "2026-06-04-history-entry" 2>&1)
rc=$?
[ "$rc" -eq 2 ] && { echo "  ✓ exit 2 (history-block row not matched)"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (history-block row was removed!)"; FAIL=$((FAIL+1)); }
grep -q '| \[\[2026-06-04-history-entry\]\] | S | M | shipped | historical row inside details |' "$TMP/PERSO/demo/BACKLOG.md" \
  && { echo "  ✓ historical row content preserved"; PASS=$((PASS+1)); } \
  || { echo "  ✗ historical row removed by Tier 1 (bug!)"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "no active row found" \
  && { echo "  ✓ error message clarifies <details> exclusion"; PASS=$((PASS+1)); } \
  || { echo "  ✗ error wording missing (got: $out)"; FAIL=$((FAIL+1)); }
teardown

# ── Check 4 — missing --task → exit 2 ───────────────────────────────────
echo ""
echo "Check 4 — missing required --task"
setup
plant_backlog
out=$("$FORGE_CONTEXT" remove-backlog-row 2>&1)
rc=$?
[ "$rc" -eq 2 ] && { echo "  ✓ missing --task → exit 2"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (expected 2)"; FAIL=$((FAIL+1)); }
teardown

# ── Check 5 — aliased wikilink row [[slug|Title]] removed by slug ────────
# add-backlog-row --label writes rows as [[slug\|Visible Title]] (the pipe is
# backslash-escaped inside markdown tables). The plain [[slug]] needle never
# matched those, so aliased rows were un-removable via Tier 1.
echo ""
echo "Check 5 — aliased wikilink row removed by slug"
setup
cat > "$TMP/PERSO/demo/BACKLOG.md" <<'EOF'
# demo — Backlog

## Hot

| Task | Effort | Impact | Status | Notes |
|------|:--:|:--:|------|-------|
| [[2026-08-07-aliased-row\|Nice Title]] | S | S | open | aliased link row |
| [[2026-06-08-plain-row]] | M | L | open | plain link row |
EOF
out=$("$FORGE_CONTEXT" remove-backlog-row --task "2026-08-07-aliased-row" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && { echo "  ✓ exit 0"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (out: $out)"; FAIL=$((FAIL+1)); }
grep -q 'aliased-row' "$TMP/PERSO/demo/BACKLOG.md" \
  && { echo "  ✗ aliased row still present"; FAIL=$((FAIL+1)); } \
  || { echo "  ✓ aliased row removed"; PASS=$((PASS+1)); }
grep -q '2026-06-08-plain-row' "$TMP/PERSO/demo/BACKLOG.md" \
  && { echo "  ✓ plain sibling untouched"; PASS=$((PASS+1)); } \
  || { echo "  ✗ plain sibling mutated"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "── Total: $PASS pass, $FAIL fail ──"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
