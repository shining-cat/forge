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
  # Audit sections (open-task / BACKLOG-staleness) are gated on maintainer mode
  # inside do_recover; end-user mode silently skips them. Tests target the
  # audit-section behavior directly, so force maintainer mode here.
  echo "MAINTAINER_MODE=true" >> "$TMP_CONF"
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

# Plant a task file with caller-supplied frontmatter (full FM block as $3,
# without the surrounding `---` fences). Mtime backdated as in plant_task.
plant_task_with_fm() {
  local path="$1" age_days="$2" fm="$3"
  {
    echo "---"
    echo "$fm"
    echo "---"
    echo ""
    echo "# Old task"
  } > "$path"
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

# ── Check 5 — stale task listed in BACKLOG active table is suppressed ───
echo ""
echo "Check 5 — stale task present in BACKLOG active table is suppressed"
setup
plant_task "$TMP/PERSO/demo/tasks/open/2026-04-01-in-backlog.md" 14
plant_task "$TMP/PERSO/demo/tasks/open/2026-04-01-not-in-backlog.md" 14
: > "$TMP/PERSO/demo/current-checkpoint.md"
# BACKLOG with one task in the active table; the other absent entirely.
cat > "$TMP/PERSO/demo/BACKLOG.md" <<'EOF'
# demo BACKLOG

| Task | Effort |
|---|---|
| [[2026-04-01-in-backlog]] | S |
EOF
# Touch backlog to "now" to avoid the separate BACKLOG-staleness signal
# coupling into this test.
touch "$TMP/PERSO/demo/BACKLOG.md"

out=$("$FORGE_CONTEXT" recover 2>&1)
echo "$out" | grep -q "2026-04-01-in-backlog.md" \
  && { echo "  ✗ task listed in BACKLOG active table was flagged"; FAIL=$((FAIL+1)); } \
  || { echo "  ✓ task in BACKLOG active table suppressed"; PASS=$((PASS+1)); }
echo "$out" | grep -q "2026-04-01-not-in-backlog.md" \
  && { echo "  ✓ task absent from BACKLOG still flagged"; PASS=$((PASS+1)); } \
  || { echo "  ✗ task absent from BACKLOG was wrongly suppressed"; FAIL=$((FAIL+1)); }
teardown

# ── Check 6 — task only mentioned in <details> block is NOT suppressed ──
echo ""
echo "Check 6 — task only in <details> history block is NOT suppressed"
setup
plant_task "$TMP/PERSO/demo/tasks/open/2026-04-01-history-only.md" 14
: > "$TMP/PERSO/demo/current-checkpoint.md"
# BACKLOG where the slug only appears inside the collapsed history block.
# The audit must IGNORE that mention — history-block presence means the work
# previously shipped or got touched, not that the Keeper considers it open.
cat > "$TMP/PERSO/demo/BACKLOG.md" <<'EOF'
# demo BACKLOG

| Task | Effort |
|---|---|
| (no active rows) | — |

<details>
<summary>Recently shipped</summary>

- PR #1 — touched [[2026-04-01-history-only]] as a related artifact.

</details>
EOF
touch "$TMP/PERSO/demo/BACKLOG.md"

out=$("$FORGE_CONTEXT" recover 2>&1)
echo "$out" | grep -q "2026-04-01-history-only.md" \
  && { echo "  ✓ task only in <details> history block still flagged"; PASS=$((PASS+1)); } \
  || { echo "  ✗ task only in <details> history block was wrongly suppressed"; FAIL=$((FAIL+1)); }
teardown

# ── Check 7 — no audit output when nothing is stale ─────────────────────
echo ""
echo "Check 7 — clean vault produces no audit sections"
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

# ── Check 8 — park: true suppresses staleness flag, control still flags ─
echo ""
echo "Check 8 — park: true suppresses staleness flag"
setup
plant_task_with_fm "$TMP/PERSO/demo/tasks/open/2026-04-01-parked.md" 14 \
  "created: 2026-04-01
status: open
park: true
park_reason: \"Read at event-time, not actionable now.\""
plant_task "$TMP/PERSO/demo/tasks/open/2026-04-01-control.md" 14
: > "$TMP/PERSO/demo/current-checkpoint.md"

out=$("$FORGE_CONTEXT" recover 2>&1)
echo "$out" | grep -q "2026-04-01-parked.md" \
  && { echo "  ✗ park:true task wrongly flagged"; FAIL=$((FAIL+1)); } \
  || { echo "  ✓ park:true task suppressed"; PASS=$((PASS+1)); }
echo "$out" | grep -q "2026-04-01-control.md" \
  && { echo "  ✓ control task still flagged"; PASS=$((PASS+1)); } \
  || { echo "  ✗ control task wrongly suppressed"; FAIL=$((FAIL+1)); }
teardown

# ── Check 9 — status: blocked suppresses staleness flag ─────────────────
echo ""
echo "Check 9 — status: blocked suppresses staleness flag"
setup
plant_task_with_fm "$TMP/PERSO/demo/tasks/open/2026-04-01-blocked.md" 14 \
  "created: 2026-04-01
status: blocked"
plant_task "$TMP/PERSO/demo/tasks/open/2026-04-01-control.md" 14
: > "$TMP/PERSO/demo/current-checkpoint.md"

out=$("$FORGE_CONTEXT" recover 2>&1)
echo "$out" | grep -q "2026-04-01-blocked.md" \
  && { echo "  ✗ status:blocked task wrongly flagged"; FAIL=$((FAIL+1)); } \
  || { echo "  ✓ status:blocked task suppressed"; PASS=$((PASS+1)); }
echo "$out" | grep -q "2026-04-01-control.md" \
  && { echo "  ✓ control task still flagged"; PASS=$((PASS+1)); } \
  || { echo "  ✗ control task wrongly suppressed"; FAIL=$((FAIL+1)); }
teardown

# ── Check 10 — status: needs-refinement suppresses staleness flag ───────
echo ""
echo "Check 10 — status: needs-refinement suppresses staleness flag"
setup
plant_task_with_fm "$TMP/PERSO/demo/tasks/open/2026-04-01-needs-refinement.md" 14 \
  "created: 2026-04-01
status: needs-refinement
awaiting: design-headspace"
plant_task "$TMP/PERSO/demo/tasks/open/2026-04-01-control.md" 14
: > "$TMP/PERSO/demo/current-checkpoint.md"

out=$("$FORGE_CONTEXT" recover 2>&1)
echo "$out" | grep -q "2026-04-01-needs-refinement.md" \
  && { echo "  ✗ status:needs-refinement task wrongly flagged"; FAIL=$((FAIL+1)); } \
  || { echo "  ✓ status:needs-refinement task suppressed"; PASS=$((PASS+1)); }
echo "$out" | grep -q "2026-04-01-control.md" \
  && { echo "  ✓ control task still flagged"; PASS=$((PASS+1)); } \
  || { echo "  ✗ control task wrongly suppressed"; FAIL=$((FAIL+1)); }
teardown

# ── Check 11 — BACKLOG audit ignores wikilinks in <details>...</details> ──
# Regression guard for the false-positive that an active row whose
# description prose mentions "Recently shipped" would trip a naive
# text-marker cutoff. The fix uses <details>/</details> as the cut.
echo ""
echo "Check 11 — BACKLOG audit ignores wikilinks in <details> history block"
setup
# 5 active wikilinks (matches 5 open task files → no row-count divergence).
# 20 wikilinks inside <details> (history; must be ignored).
# One active row whose description PROSE mentions "Recently shipped" —
# would trip a naive `/Recently shipped/ { exit }` cutoff and lose the
# active wikilinks below it.
for i in 1 2 3 4 5; do
  plant_task "$TMP/PERSO/demo/tasks/open/2026-04-0${i}-active${i}.md" 1
done
cat > "$TMP/PERSO/demo/BACKLOG.md" <<'EOF'
# demo BACKLOG

## Active

| Task | Effort |
|---|---|
| [[2026-04-01-active1]] | S |
| [[2026-04-02-active2]] | S |
| [[2026-04-03-active3]] | S — mentions "Recently shipped" in this prose to trap naive cutoffs |
| [[2026-04-04-active4]] | S |
| [[2026-04-05-active5]] | S |

<details>
<summary><b>📜 Recently shipped — click to expand</b></summary>

- [[2026-03-01-old1]] [[2026-03-02-old2]] [[2026-03-03-old3]] [[2026-03-04-old4]]
- [[2026-03-05-old5]] [[2026-03-06-old6]] [[2026-03-07-old7]] [[2026-03-08-old8]]
- [[2026-03-09-old9]] [[2026-03-10-old10]] [[2026-03-11-old11]] [[2026-03-12-old12]]
- [[2026-03-13-old13]] [[2026-03-14-old14]] [[2026-03-15-old15]] [[2026-03-16-old16]]
- [[2026-03-17-old17]] [[2026-03-18-old18]] [[2026-03-19-old19]] [[2026-03-20-old20]]
</details>
EOF
# Touch BACKLOG to "now" so the mtime-gap signal doesn't coincidentally fire.
touch "$TMP/PERSO/demo/BACKLOG.md"
: > "$TMP/PERSO/demo/current-checkpoint.md"

out=$("$FORGE_CONTEXT" recover 2>&1)
echo "$out" | grep -q "row count diverges" \
  && { echo "  ✗ active=5 vs open=5 + 20 historical wikilinks wrongly flagged as diverging"; FAIL=$((FAIL+1)); } \
  || { echo "  ✓ healthy BACKLOG with 20 historical wikilinks not flagged"; PASS=$((PASS+1)); }
teardown

# ── Check 12 — divergence still fires when active region is genuinely off ──
# Regression guard for the OPPOSITE: don't over-correct and silence real
# drift. Active region has 1 wikilink; tasks/open/ has 5 → diverges by 4
# (exceeds the slack of 3) → MUST still flag.
echo ""
echo "Check 12 — divergence still fires when active region is genuinely off"
setup
for i in 1 2 3 4 5; do
  plant_task "$TMP/PERSO/demo/tasks/open/2026-04-0${i}-task${i}.md" 1
done
cat > "$TMP/PERSO/demo/BACKLOG.md" <<'EOF'
# demo BACKLOG

| Task | Effort |
|---|---|
| [[2026-04-01-task1]] | S |

<details>
<summary>📜 Recently shipped</summary>

- [[2026-03-01-old1]] [[2026-03-02-old2]] [[2026-03-03-old3]]
</details>
EOF
touch "$TMP/PERSO/demo/BACKLOG.md"
: > "$TMP/PERSO/demo/current-checkpoint.md"

out=$("$FORGE_CONTEXT" recover 2>&1)
echo "$out" | grep -q "row count diverges (1 wikilinks vs 5 open tasks)" \
  && { echo "  ✓ real drift still flagged with correct counts (1 active vs 5 open)"; PASS=$((PASS+1)); } \
  || { echo "  ✗ real drift missed or counts wrong"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
