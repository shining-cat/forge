#!/usr/bin/env bash
# Tests forge-context.sh add-recently-shipped (Tier 1 vault-write subcommand).
#
# Behavior under test:
#  - Empty Recently-shipped block → entry becomes first/only entry
#  - Non-empty block → new entry inserted at top, prior entries preserved
#  - Missing <summary> opener → exit 2 with named error

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

plant_empty_block_backlog() {
  cat > "$TMP/PERSO/demo/BACKLOG.md" <<'EOF'
# demo — Backlog

**Updated:** 2026-06-08 09:00 CEST • **Active:** 1 rows • **Dormant:** 0 • **Latest:** stub.

| Task | Effort | Impact | Status | Notes |
|------|:--:|:--:|------|-------|
| [[2026-06-08-task]] | S | M | open | x |

<details>
<summary><b>Recently shipped</b></summary>

</details>
EOF
}

plant_non_empty_block_backlog() {
  cat > "$TMP/PERSO/demo/BACKLOG.md" <<'EOF'
# demo — Backlog

**Updated:** 2026-06-08 09:00 CEST • **Active:** 1 rows • **Dormant:** 0 • **Latest:** stub.

| Task | Effort | Impact | Status | Notes |
|------|:--:|:--:|------|-------|
| [[2026-06-08-task]] | S | M | open | x |

<details>
<summary><b>Recently shipped</b></summary>

> **Shipped 2026-06-07 14:00 — earlier entry title:**
> - PR #42 — body of prior entry.

</details>
EOF
}

# ── Check 1 — empty block: entry becomes first/only entry ───────────────
echo "Check 1 — empty Recently-shipped block"
setup
plant_empty_block_backlog
out=$("$FORGE_CONTEXT" add-recently-shipped \
  --date "2026-06-09 10:30" \
  --title "first entry title" \
  --body - <<'EOF' 2>&1
> - PR #92 — first entry body.
> - second body line.
EOF
)
rc=$?
[ "$rc" -eq 0 ] && { echo "  ✓ exit 0"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (out: $out)"; FAIL=$((FAIL+1)); }
grep -q '^> \*\*Shipped 2026-06-09 10:30 — first entry title:\*\*$' "$TMP/PERSO/demo/BACKLOG.md" \
  && { echo "  ✓ entry header present in expected format"; PASS=$((PASS+1)); } \
  || { echo "  ✗ entry header missing"; FAIL=$((FAIL+1)); }
grep -q '^> - PR #92 — first entry body\.$' "$TMP/PERSO/demo/BACKLOG.md" \
  && { echo "  ✓ entry body preserved verbatim"; PASS=$((PASS+1)); } \
  || { echo "  ✗ entry body missing"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "^\[add-recently-shipped\] entry prepended" \
  && { echo "  ✓ stdout success line present"; PASS=$((PASS+1)); } \
  || { echo "  ✗ stdout missing"; FAIL=$((FAIL+1)); }
teardown

# ── Check 2 — non-empty block: new entry inserted at top, prior preserved ──
echo ""
echo "Check 2 — non-empty block: new entry at top, prior preserved"
setup
plant_non_empty_block_backlog
"$FORGE_CONTEXT" add-recently-shipped \
  --date "2026-06-09 11:00" \
  --title "newest entry" \
  --body - <<'EOF' >/dev/null 2>&1
> - PR #93 — newer body.
EOF
# Verify both old + new exist
grep -q '^> \*\*Shipped 2026-06-09 11:00 — newest entry:\*\*$' "$TMP/PERSO/demo/BACKLOG.md" \
  && { echo "  ✓ new entry present"; PASS=$((PASS+1)); } \
  || { echo "  ✗ new entry missing"; FAIL=$((FAIL+1)); }
grep -q '^> \*\*Shipped 2026-06-07 14:00 — earlier entry title:\*\*$' "$TMP/PERSO/demo/BACKLOG.md" \
  && { echo "  ✓ prior entry preserved"; PASS=$((PASS+1)); } \
  || { echo "  ✗ prior entry lost"; FAIL=$((FAIL+1)); }
# Verify order: new entry's line number comes BEFORE prior entry's line number.
new_line=$(grep -n '^> \*\*Shipped 2026-06-09 11:00' "$TMP/PERSO/demo/BACKLOG.md" | cut -d: -f1)
old_line=$(grep -n '^> \*\*Shipped 2026-06-07 14:00' "$TMP/PERSO/demo/BACKLOG.md" | cut -d: -f1)
if [ -n "$new_line" ] && [ -n "$old_line" ] && [ "$new_line" -lt "$old_line" ]; then
  echo "  ✓ new entry positioned above prior entry"; PASS=$((PASS+1))
else
  echo "  ✗ new entry not at top (new line $new_line, old line $old_line)"; FAIL=$((FAIL+1))
fi
teardown

# ── Check 3 — missing <summary> → exit 2 ────────────────────────────────
echo ""
echo "Check 3 — missing <summary> opener → exit 2"
setup
cat > "$TMP/PERSO/demo/BACKLOG.md" <<'EOF'
# demo — Backlog

**Updated:** 2026-06-08 09:00 CEST • **Active:** 1 rows • **Dormant:** 0 • **Latest:** stub.

Plain content. No details block.
EOF
out=$("$FORGE_CONTEXT" add-recently-shipped --date "2026-06-09 10:30" --title "nope" --body - <<'EOF' 2>&1
> body
EOF
)
rc=$?
[ "$rc" -eq 2 ] && { echo "  ✓ exit 2 on missing summary"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (expected 2)"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "no '<summary>' opener" \
  && { echo "  ✓ named-error explains the gap"; PASS=$((PASS+1)); } \
  || { echo "  ✗ named-error missing (got: $out)"; FAIL=$((FAIL+1)); }
teardown

# ── Check 4 — missing required args ─────────────────────────────────────
echo ""
echo "Check 4 — missing required args"
setup
plant_empty_block_backlog
out=$("$FORGE_CONTEXT" add-recently-shipped --title "no-date" --body - <<<"body" 2>&1)
rc=$?
[ "$rc" -eq 2 ] && { echo "  ✓ missing --date → exit 2"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (expected 2)"; FAIL=$((FAIL+1)); }
out=$("$FORGE_CONTEXT" add-recently-shipped --date "2026-06-09 10:30" --body - <<<"body" 2>&1)
rc=$?
[ "$rc" -eq 2 ] && { echo "  ✓ missing --title → exit 2"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "── Total: $PASS pass, $FAIL fail ──"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
