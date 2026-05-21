#!/usr/bin/env bash
# Tests do_recover's open-task + BACKLOG staleness audits.
# These run as part of `recover` (not their own subcommands), so the harness
# stands up a mock vault, points the marker at a fake project, and inspects
# the recover output for the audit sections.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_CONTEXT="$SCRIPT_DIR/../forge-context.sh"

PASS=0; FAIL=0

setup() {
  TMP=$(mktemp -d)
  TMP_CONF="$TMP/forge.conf"
  echo "VAULT_PATH=$TMP" > "$TMP_CONF"
  echo "REPO_ROOTS=$TMP/repos" >> "$TMP_CONF"
  mkdir -p "$TMP/_shared" "$TMP/repos/demo"
  # Real git repo on the mock project so recover's `git -C $PROJECT_DIR ...`
  # calls don't exit non-zero under set -euo pipefail (which would abort
  # recover before reaching the audit sections).
  git -C "$TMP/repos/demo" init -q 2>/dev/null
  git -C "$TMP/repos/demo" -c user.email=t@e -c user.name=t \
    commit --allow-empty -q -m init 2>/dev/null

  mkdir -p "$TMP/PERSO/demo/tasks/open" "$TMP/PERSO/demo/tasks/resolved"
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

# Plant a task file with mtime set N days ago.
plant_task() {
  local path="$1" age_days="$2"
  cat > "$path" <<'EOF'
---
created: 2026-04-01
status: open
---

# Old task
EOF
  # Backdate mtime so the audit's mtime-based threshold trips.
  local target_epoch
  target_epoch=$(( $(date +%s) - (age_days * 86400) ))
  touch -t "$(date -r "$target_epoch" '+%Y%m%d%H%M.%S' 2>/dev/null \
              || date -d "@$target_epoch" '+%Y%m%d%H%M.%S' 2>/dev/null)" "$path"
}

# ── Check 1 — stale tasks surface, fresh tasks don't ────────────────────
echo "Check 1 — stale tasks surface, fresh tasks don't"
setup
plant_task "$TMP/PERSO/demo/tasks/open/2026-04-01-old-stale.md" 14
plant_task "$TMP/PERSO/demo/tasks/open/2026-05-20-fresh.md" 1
# Empty checkpoint so the slug-mention filter doesn't suppress anything.
: > "$TMP/PERSO/demo/current-checkpoint.md"

out=$("$FORGE_CONTEXT" recover 2>&1)
echo "$out" | grep -q "Open-Task Audit" \
  && { echo "  ✓ Open-Task Audit section present"; PASS=$((PASS+1)); } \
  || { echo "  ✗ Open-Task Audit section missing"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "2026-04-01-old-stale.md" \
  && { echo "  ✓ stale task surfaces"; PASS=$((PASS+1)); } \
  || { echo "  ✗ stale task missed"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "2026-05-20-fresh.md" \
  && { echo "  ✗ fresh task incorrectly flagged"; FAIL=$((FAIL+1)); } \
  || { echo "  ✓ fresh task correctly suppressed"; PASS=$((PASS+1)); }
teardown

# ── Check 2 — task mentioned in checkpoint is suppressed ────────────────
echo ""
echo "Check 2 — task mentioned in checkpoint is suppressed"
setup
plant_task "$TMP/PERSO/demo/tasks/open/2026-04-01-mentioned.md" 14
plant_task "$TMP/PERSO/demo/tasks/open/2026-04-01-unmentioned.md" 14
cat > "$TMP/PERSO/demo/current-checkpoint.md" <<'EOF'
# Checkpoint
In progress: [[2026-04-01-mentioned]]
EOF

out=$("$FORGE_CONTEXT" recover 2>&1)
echo "$out" | grep -q "2026-04-01-mentioned.md" \
  && { echo "  ✗ mentioned task wrongly surfaced"; FAIL=$((FAIL+1)); } \
  || { echo "  ✓ mentioned task suppressed"; PASS=$((PASS+1)); }
echo "$out" | grep -q "2026-04-01-unmentioned.md" \
  && { echo "  ✓ unmentioned task surfaces"; PASS=$((PASS+1)); } \
  || { echo "  ✗ unmentioned task missed"; FAIL=$((FAIL+1)); }
teardown

# ── Check 3 — legacy done/ folder flagged as migration prompt ───────────
echo ""
echo "Check 3 — legacy done/ folder flagged as migration prompt"
setup
mkdir -p "$TMP/PERSO/demo/tasks/done"
echo "stub" > "$TMP/PERSO/demo/tasks/done/legacy1.md"
echo "stub" > "$TMP/PERSO/demo/tasks/done/legacy2.md"

out=$("$FORGE_CONTEXT" recover 2>&1)
echo "$out" | grep -q "Legacy 'done/' folder" \
  && { echo "  ✓ done/ migration header present"; PASS=$((PASS+1)); } \
  || { echo "  ✗ done/ migration header missing"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "PERSO/demo: tasks/done/ exists (2 files)" \
  && { echo "  ✓ done/ file count reported"; PASS=$((PASS+1)); } \
  || { echo "  ✗ done/ file count wrong or missing"; FAIL=$((FAIL+1)); }
teardown

# ── Check 4 — BACKLOG mtime gap >= 1d flagged, <1d suppressed ───────────
echo ""
echo "Check 4 — BACKLOG mtime gap"
setup
plant_task "$TMP/PERSO/demo/tasks/open/2026-04-01-old.md" 14
# Stale BACKLOG: older than recent task activity by >= 1d
echo "# demo BACKLOG" > "$TMP/PERSO/demo/BACKLOG.md"
stale_epoch=$(( $(date +%s) - (3 * 86400) ))
touch -t "$(date -r "$stale_epoch" '+%Y%m%d%H%M.%S' 2>/dev/null \
            || date -d "@$stale_epoch" '+%Y%m%d%H%M.%S' 2>/dev/null)" \
      "$TMP/PERSO/demo/BACKLOG.md"
# Touch a task file to "now" so the gap is real
touch "$TMP/PERSO/demo/tasks/open/2026-04-01-old.md"

out=$("$FORGE_CONTEXT" recover 2>&1)
echo "$out" | grep -q "BACKLOG Staleness" \
  && { echo "  ✓ BACKLOG Staleness section present when stale"; PASS=$((PASS+1)); } \
  || { echo "  ✗ BACKLOG Staleness section missing when stale"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "PERSO/demo: older than tasks/ activity" \
  && { echo "  ✓ specific drift line reported"; PASS=$((PASS+1)); } \
  || { echo "  ✗ specific drift line missing"; FAIL=$((FAIL+1)); }

# Now refresh BACKLOG to "now" — gap < 1d, should suppress
touch "$TMP/PERSO/demo/BACKLOG.md"
out2=$("$FORGE_CONTEXT" recover 2>&1)
echo "$out2" | grep -q "BACKLOG Staleness" \
  && { echo "  ✗ BACKLOG Staleness shown when gap <1d"; FAIL=$((FAIL+1)); } \
  || { echo "  ✓ BACKLOG Staleness suppressed when gap <1d"; PASS=$((PASS+1)); }
teardown

# ── Check 5 — no audit output when nothing is stale ─────────────────────
echo ""
echo "Check 5 — clean vault produces no audit sections"
setup
plant_task "$TMP/PERSO/demo/tasks/open/2026-05-20-fresh.md" 1
: > "$TMP/PERSO/demo/current-checkpoint.md"

out=$("$FORGE_CONTEXT" recover 2>&1)
echo "$out" | grep -q "Open-Task Audit" \
  && { echo "  ✗ Open-Task Audit present on clean vault"; FAIL=$((FAIL+1)); } \
  || { echo "  ✓ Open-Task Audit absent on clean vault"; PASS=$((PASS+1)); }
echo "$out" | grep -q "BACKLOG Staleness" \
  && { echo "  ✗ BACKLOG Staleness present on clean vault"; FAIL=$((FAIL+1)); } \
  || { echo "  ✓ BACKLOG Staleness absent on clean vault"; PASS=$((PASS+1)); }
teardown

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
