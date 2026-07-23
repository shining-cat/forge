#!/usr/bin/env bash
# Tests forge-context.sh add-backlog-row (Tier 1 vault-write subcommand).
#
# Behavior under test:
#  - Happy path → new row spliced under the named section, glyphs rendered,
#    siblings + other sections untouched
#  - Dup guard → [[slug]] already present anywhere → exit 2, file untouched
#  - Section not found → exit 2 with named error
#  - Missing required args → exit 2
#  - --label → [[slug|label]] link form
#  - Row lands in the RIGHT section (not the first table in the file)

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

**Updated:** 2026-06-08 09:00 CEST • **Active:** 2 rows • **Dormant:** 0 • **Latest:** stub.

## Security / discipline

| Task | Effort | Impact | Status | Notes |
|------|:--:|:--:|:--:|-------|

## Hot

| Task | Effort | Impact | Status | Notes |
|------|:--:|:--:|------|-------|
| [[2026-06-08-existing-one]] | S | M | open | already here |

<details>
<summary><b>Recently shipped</b></summary>

| Task | Effort | Impact | Status | Notes |
|------|:--:|:--:|------|-------|
| [[2026-06-04-history-entry]] | S | M | shipped | historical row inside details |

</details>
EOF
}

# ── Check 1 — happy path: row spliced under Hot ─────────────────────────
echo "Check 1 — happy path: row added under 'Hot'"
setup; plant_backlog
out=$("$FORGE_CONTEXT" add-backlog-row \
  --task "2026-06-08-new-row" --section "Hot" \
  --effort S --impact M --status open \
  --notes "brand new work" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && { echo "  ✓ exit 0"; PASS=$((PASS+1)); } || { echo "  ✗ exit $rc (out: $out)"; FAIL=$((FAIL+1)); }
nl=$(grep '\[\[2026-06-08-new-row\]\]' "$TMP/PERSO/demo/BACKLOG.md")
[ -n "$nl" ] && { echo "  ✓ new row present"; PASS=$((PASS+1)); } || { echo "  ✗ new row missing"; FAIL=$((FAIL+1)); }
echo "$nl" | grep -q 'font-size:0.85em' && echo "$nl" | grep -q '🟦' \
  && { echo "  ✓ effort glyph rendered"; PASS=$((PASS+1)); } || { echo "  ✗ effort not rendered (got: $nl)"; FAIL=$((FAIL+1)); }
echo "$nl" | grep -q '🟪' && { echo "  ✓ impact glyph rendered"; PASS=$((PASS+1)); } || { echo "  ✗ impact not rendered"; FAIL=$((FAIL+1)); }
echo "$nl" | grep -q '⚪<br>open' && { echo "  ✓ status glyph rendered"; PASS=$((PASS+1)); } || { echo "  ✗ status not rendered"; FAIL=$((FAIL+1)); }
echo "$nl" | grep -q 'brand new work' && { echo "  ✓ notes present"; PASS=$((PASS+1)); } || { echo "  ✗ notes missing"; FAIL=$((FAIL+1)); }
# Sibling untouched
grep -q '| \[\[2026-06-08-existing-one\]\] | S | M | open | already here |' "$TMP/PERSO/demo/BACKLOG.md" \
  && { echo "  ✓ sibling row untouched"; PASS=$((PASS+1)); } || { echo "  ✗ sibling mutated"; FAIL=$((FAIL+1)); }
teardown

# ── Check 2 — row lands under the NAMED section, not the first table ─────
echo ""
echo "Check 2 — row lands under 'Hot', not 'Security / discipline'"
setup; plant_backlog
"$FORGE_CONTEXT" add-backlog-row --task "2026-06-08-placed" --section "Hot" \
  --effort M --impact L --status next >/dev/null 2>&1
# The new row must appear AFTER the '## Hot' header, and the Security table
# (first in the file) must remain empty (only header + separator).
hot_line=$(grep -n '## Hot' "$TMP/PERSO/demo/BACKLOG.md" | head -1 | cut -d: -f1)
new_line=$(grep -n '\[\[2026-06-08-placed\]\]' "$TMP/PERSO/demo/BACKLOG.md" | head -1 | cut -d: -f1)
[ -n "$hot_line" ] && [ -n "$new_line" ] && [ "$new_line" -gt "$hot_line" ] \
  && { echo "  ✓ row placed after '## Hot' header"; PASS=$((PASS+1)); } \
  || { echo "  ✗ row misplaced (hot=$hot_line new=$new_line)"; FAIL=$((FAIL+1)); }
teardown

# ── Check 3 — dup guard: existing slug refused ──────────────────────────
echo ""
echo "Check 3 — dup guard (slug already present) → exit 2, no change"
setup; plant_backlog
before=$(md5 -q "$TMP/PERSO/demo/BACKLOG.md" 2>/dev/null || md5sum "$TMP/PERSO/demo/BACKLOG.md" | cut -d' ' -f1)
out=$("$FORGE_CONTEXT" add-backlog-row --task "2026-06-08-existing-one" --section "Hot" \
  --effort S --impact M --status open 2>&1)
rc=$?
[ "$rc" -eq 2 ] && { echo "  ✓ exit 2 on dup"; PASS=$((PASS+1)); } || { echo "  ✗ exit $rc (expected 2)"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "already present" && { echo "  ✓ named dup error"; PASS=$((PASS+1)); } || { echo "  ✗ error wording missing (got: $out)"; FAIL=$((FAIL+1)); }
after=$(md5 -q "$TMP/PERSO/demo/BACKLOG.md" 2>/dev/null || md5sum "$TMP/PERSO/demo/BACKLOG.md" | cut -d' ' -f1)
[ "$before" = "$after" ] && { echo "  ✓ file unchanged on dup"; PASS=$((PASS+1)); } || { echo "  ✗ file mutated on dup"; FAIL=$((FAIL+1)); }
teardown

# ── Check 4 — dup guard also catches slug inside <details> ──────────────
echo ""
echo "Check 4 — slug present only in <details> still refused"
setup; plant_backlog
out=$("$FORGE_CONTEXT" add-backlog-row --task "2026-06-04-history-entry" --section "Hot" \
  --effort S --impact M --status open 2>&1)
rc=$?
[ "$rc" -eq 2 ] && { echo "  ✓ exit 2 (history slug blocks re-add)"; PASS=$((PASS+1)); } || { echo "  ✗ exit $rc"; FAIL=$((FAIL+1)); }
teardown

# ── Check 5 — section not found → exit 2 ────────────────────────────────
echo ""
echo "Check 5 — unknown section → exit 2"
setup; plant_backlog
out=$("$FORGE_CONTEXT" add-backlog-row --task "2026-06-08-nope" --section "Nonexistent Section" \
  --effort S --impact M --status open 2>&1)
rc=$?
[ "$rc" -eq 2 ] && { echo "  ✓ exit 2 on missing section"; PASS=$((PASS+1)); } || { echo "  ✗ exit $rc"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "not found" && { echo "  ✓ named-error explains the miss"; PASS=$((PASS+1)); } || { echo "  ✗ error wording missing (got: $out)"; FAIL=$((FAIL+1)); }
teardown

# ── Check 6 — missing required args → exit 2 ────────────────────────────
echo ""
echo "Check 6 — missing required args"
setup; plant_backlog
"$FORGE_CONTEXT" add-backlog-row --section "Hot" --effort S --impact M --status open >/dev/null 2>&1
[ "$?" -eq 2 ] && { echo "  ✓ missing --task → exit 2"; PASS=$((PASS+1)); } || { echo "  ✗ no exit 2 on missing --task"; FAIL=$((FAIL+1)); }
"$FORGE_CONTEXT" add-backlog-row --task "2026-06-08-x" --effort S --impact M --status open >/dev/null 2>&1
[ "$?" -eq 2 ] && { echo "  ✓ missing --section → exit 2"; PASS=$((PASS+1)); } || { echo "  ✗ no exit 2 on missing --section"; FAIL=$((FAIL+1)); }
"$FORGE_CONTEXT" add-backlog-row --task "2026-06-08-x" --section "Hot" --impact M --status open >/dev/null 2>&1
[ "$?" -eq 2 ] && { echo "  ✓ missing --effort → exit 2"; PASS=$((PASS+1)); } || { echo "  ✗ no exit 2 on missing --effort"; FAIL=$((FAIL+1)); }
teardown

# ── Check 7 — --label produces [[slug|label]] ───────────────────────────
echo ""
echo "Check 7 — --label yields [[slug|label]] link"
setup; plant_backlog
"$FORGE_CONTEXT" add-backlog-row --task "2026-06-08-labelled" --section "Hot" \
  --effort S --impact M --status open --label "Short name" >/dev/null 2>&1
grep -q '\[\[2026-06-08-labelled|Short name\]\]' "$TMP/PERSO/demo/BACKLOG.md" \
  && { echo "  ✓ labelled link rendered"; PASS=$((PASS+1)); } || { echo "  ✗ label not applied"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "── Total: $PASS pass, $FAIL fail ──"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
