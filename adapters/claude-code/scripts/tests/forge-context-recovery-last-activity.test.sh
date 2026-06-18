#!/usr/bin/env bash
# Tests do_recover's "Last project activity" block
# (2026-06-13-entry-summary-per-project-last-touched).
#
# Surfaces honest project recency from two trustworthy sources — checkpoint
# frontmatter `date:` and last vault commit touching the project dir — instead
# of the mtime-based "Checkpoint: N minutes ago" which Obsidian sync / marker
# writes contaminate. Shows a divergence note when vault activity postdates the
# last genuine checkpoint refresh.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_CONTEXT="$SCRIPT_DIR/../forge-context.sh"

PASS=0; FAIL=0

date_days_ago() { date -v-"$1"d +%Y-%m-%d 2>/dev/null || date -d "$1 days ago" +%Y-%m-%d 2>/dev/null; }

setup() {
  TMP=$(mktemp -d)
  TMP_CONF="$TMP/forge.conf"
  { echo "VAULT_PATH=$TMP"; echo "REPO_ROOTS=$TMP/repos"; } > "$TMP_CONF"
  mkdir -p "$TMP/_shared" "$TMP/repos/demo" "$TMP/PERSO/demo"
  # Code repo for the project (recover's `git -C $PROJECT_DIR` calls).
  git -C "$TMP/repos/demo" init -q
  git -C "$TMP/repos/demo" -c user.email=t@e -c user.name=t commit --allow-empty -q -m init
  # Vault root is its own git repo (so `git -C $vault_proj_dir log` resolves).
  git -C "$TMP" init -q
  git -C "$TMP" config user.email t@e
  git -C "$TMP" config user.name t
  cat > "$TMP/_shared/forge-active" <<EOF
{"session_id":"test-session","project":"demo","started_at":"2026-05-21T13:00:00+0200","tmux_pane":null}
EOF
  export FORGE_CONF_OVERRIDE="$TMP_CONF"
  export CLAUDE_CODE_SESSION_ID="test-session"
}

teardown() {
  rm -rf "$TMP"
  unset FORGE_CONF_OVERRIDE CLAUDE_CODE_SESSION_ID TMP TMP_CONF
}

# Write a checkpoint with frontmatter date=$1, then commit it to the vault repo
# with committer date $2 (YYYY-MM-DD).
plant_checkpoint() {
  local fm_date="$1" commit_date="$2"
  cat > "$TMP/PERSO/demo/current-checkpoint.md" <<EOF
---
date: $fm_date
time: "10:00"
project: demo
session: open
---

# demo checkpoint
EOF
  git -C "$TMP" add PERSO/demo/current-checkpoint.md
  GIT_COMMITTER_DATE="${commit_date}T10:00:00" GIT_AUTHOR_DATE="${commit_date}T10:00:00" \
    git -C "$TMP" commit -q -m "checkpoint $commit_date"
}

echo "=== do_recover — Last project activity ==="

# Case 1 — divergence: frontmatter 7d ago, last vault commit 1d ago
setup
plant_checkpoint "$(date_days_ago 7)" "$(date_days_ago 1)"
out=$("$FORGE_CONTEXT" recover 2>&1)
echo "$out" | grep -q "Last project activity:" \
  && { echo "  ✓ block present"; PASS=$((PASS+1)); } \
  || { echo "  ✗ block missing"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "Checkpoint frontmatter: $(date_days_ago 7) (7d ago)" \
  && { echo "  ✓ frontmatter date + age shown"; PASS=$((PASS+1)); } \
  || { echo "  ✗ frontmatter line wrong (got: $(echo "$out" | grep -i frontmatter))"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "Last vault commit:      $(date_days_ago 1) (1d ago)" \
  && { echo "  ✓ last vault commit + age shown"; PASS=$((PASS+1)); } \
  || { echo "  ✗ commit line wrong (got: $(echo "$out" | grep -i 'vault commit'))"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "→ divergence:" \
  && { echo "  ✓ divergence note shown (commit postdates checkpoint by 6d)"; PASS=$((PASS+1)); } \
  || { echo "  ✗ divergence note missing"; FAIL=$((FAIL+1)); }
teardown

# Case 2 — no divergence: frontmatter and commit both today
setup
plant_checkpoint "$(date_days_ago 0)" "$(date_days_ago 0)"
out=$("$FORGE_CONTEXT" recover 2>&1)
echo "$out" | grep -q "Checkpoint frontmatter: $(date_days_ago 0) (0d ago)" \
  && { echo "  ✓ same-day frontmatter shown"; PASS=$((PASS+1)); } \
  || { echo "  ✗ same-day frontmatter wrong"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "→ divergence:" \
  && { echo "  ✗ divergence note shown when none expected"; FAIL=$((FAIL+1)); } \
  || { echo "  ✓ no divergence note when fresh"; PASS=$((PASS+1)); }
teardown

# Case 3 — no frontmatter date field
setup
cat > "$TMP/PERSO/demo/current-checkpoint.md" <<'EOF'
---
project: demo
session: open
---

# no date field
EOF
git -C "$TMP" add PERSO/demo/current-checkpoint.md
git -C "$TMP" commit -q -m "no-date checkpoint"
out=$("$FORGE_CONTEXT" recover 2>&1)
echo "$out" | grep -q "Checkpoint frontmatter: (no date: field)" \
  && { echo "  ✓ missing date field handled"; PASS=$((PASS+1)); } \
  || { echo "  ✗ missing date field not handled (got: $(echo "$out" | grep -i frontmatter))"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "── Total: $PASS pass, $FAIL fail ──"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
