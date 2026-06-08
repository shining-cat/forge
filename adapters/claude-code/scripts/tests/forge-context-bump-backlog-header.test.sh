#!/usr/bin/env bash
# Tests forge-context.sh bump-backlog-header (Tier 1 vault-write subcommand).
#
# Behavior under test:
#  - Header line replaced with new timestamp + active count + latest prose
#  - Dormant count preserved from prior header
#  - Active count excludes wikilinks INSIDE <details> blocks (same false-positive
#    bug PR #70 fixed for do_backlog_audit — regression guard here)

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

**Updated:** 2026-06-01 09:00 CEST • **Active:** 99 rows • **Dormant:** 4 • **Latest:** **old latest prose** — stale text from prior bump.

## Hot

| Task | Effort | Impact | Status | Notes |
|------|:--:|:--:|------|-------|
| [[2026-06-08-active-one]] | S | M | open | one |
| [[2026-06-08-active-two]] | M | H | open | two |
| [[2026-06-08-active-three]] | L | L | open | three |

## Other

| Task | Effort | Impact | Status | Notes |
|------|:--:|:--:|------|-------|
| [[2026-06-07-active-four]] | S | M | open | four |

---

<details>
<summary><b>Recently shipped</b></summary>

> **Shipped 2026-06-05:**
> - [[2026-06-04-shipped-one]] something shipped.
> - [[2026-06-03-shipped-two]] another.
> - [[2026-06-02-shipped-three]] yet another.
> - [[2026-06-01-shipped-four]] and another.

</details>
EOF
}

# ── Check 1 — header replaced with active count + latest prose ──────────
echo "Check 1 — header replaced (active count auto-computed, latest verbatim)"
setup
plant_backlog
out=$("$FORGE_CONTEXT" bump-backlog-header --latest "shipped vault-write-tier-1 (PR #92, abc1234) — 6 new subcommands." 2>&1)
rc=$?
[ "$rc" -eq 0 ] && { echo "  ✓ exit 0"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (out: $out)"; FAIL=$((FAIL+1)); }
grep -q '\*\*Active:\*\* 4 rows' "$TMP/PERSO/demo/BACKLOG.md" \
  && { echo "  ✓ active count auto-computed (4 active wikilinks, excluding details)"; PASS=$((PASS+1)); } \
  || { echo "  ✗ active count wrong (header: $(grep -m1 '\*\*Updated:\*\*' "$TMP/PERSO/demo/BACKLOG.md"))"; FAIL=$((FAIL+1)); }
grep -q 'shipped vault-write-tier-1' "$TMP/PERSO/demo/BACKLOG.md" \
  && { echo "  ✓ latest prose preserved verbatim"; PASS=$((PASS+1)); } \
  || { echo "  ✗ latest prose missing"; FAIL=$((FAIL+1)); }
grep -qE '\*\*Updated:\*\* [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} CEST' "$TMP/PERSO/demo/BACKLOG.md" \
  && { echo "  ✓ timestamp format matches expected"; PASS=$((PASS+1)); } \
  || { echo "  ✗ timestamp malformed"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "^\[bump-backlog-header\]" \
  && { echo "  ✓ stdout success line present"; PASS=$((PASS+1)); } \
  || { echo "  ✗ stdout missing"; FAIL=$((FAIL+1)); }
teardown

# ── Check 2 — Dormant count preserved from prior header ─────────────────
echo ""
echo "Check 2 — Dormant count preserved"
setup
plant_backlog
"$FORGE_CONTEXT" bump-backlog-header --latest "x" >/dev/null 2>&1
grep -q '\*\*Dormant:\*\* 4 ' "$TMP/PERSO/demo/BACKLOG.md" \
  && { echo "  ✓ Dormant preserved at 4"; PASS=$((PASS+1)); } \
  || { echo "  ✗ Dormant lost (header: $(grep -m1 '\*\*Updated:\*\*' "$TMP/PERSO/demo/BACKLOG.md"))"; FAIL=$((FAIL+1)); }
teardown

# ── Check 3 — wikilinks inside <details> NOT counted (regression of PR #70 bug) ──
echo ""
echo "Check 3 — wikilinks inside <details> NOT counted (PR #70 regression guard)"
setup
plant_backlog
# Sanity: the planted backlog has 4 active wikilinks + 4 inside <details>.
# Naive count = 8; correct count = 4. The header should show 4.
"$FORGE_CONTEXT" bump-backlog-header --latest "regression-guard" >/dev/null 2>&1
grep -q '\*\*Active:\*\* 4 rows' "$TMP/PERSO/demo/BACKLOG.md" \
  && { echo "  ✓ details-block wikilinks excluded (4 not 8)"; PASS=$((PASS+1)); } \
  || { echo "  ✗ wikilinks inside details leaked into count (got: $(grep -m1 '\*\*Updated:\*\*' "$TMP/PERSO/demo/BACKLOG.md"))"; FAIL=$((FAIL+1)); }
teardown

# ── Check 4 — missing --latest → exit 2 ─────────────────────────────────
echo ""
echo "Check 4 — missing --latest → exit 2"
setup
plant_backlog
out=$("$FORGE_CONTEXT" bump-backlog-header 2>&1)
rc=$?
[ "$rc" -eq 2 ] && { echo "  ✓ exit 2"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (expected 2)"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "latest required" \
  && { echo "  ✓ named-error mentions --latest"; PASS=$((PASS+1)); } \
  || { echo "  ✗ named-error missing"; FAIL=$((FAIL+1)); }
teardown

# ── Check 5 — body of BACKLOG (non-header lines) unchanged ──────────────
echo ""
echo "Check 5 — non-header lines unchanged"
setup
plant_backlog
md5_before=$(grep -v '\*\*Updated:\*\*' "$TMP/PERSO/demo/BACKLOG.md" | md5)
"$FORGE_CONTEXT" bump-backlog-header --latest "body-unchanged-test" >/dev/null 2>&1
md5_after=$(grep -v '\*\*Updated:\*\*' "$TMP/PERSO/demo/BACKLOG.md" | md5)
[ "$md5_before" = "$md5_after" ] \
  && { echo "  ✓ all non-header lines preserved"; PASS=$((PASS+1)); } \
  || { echo "  ✗ non-header content mutated (before=$md5_before, after=$md5_after)"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "── Total: $PASS pass, $FAIL fail ──"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
