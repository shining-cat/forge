#!/usr/bin/env bash
# Tests do_resolve_task (Plan C — script-driven task closure) and its
# auto-fire path inside do_post_tool when a `git commit` carries
# `Resolves task: <slug>` trailers.
#
# Standalone subcommand tests use direct invocation; the trailer-parse
# tests stand up a real git repo + simulated PostToolUse JSON payload.

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
  # Real git repo so optional `git mv` inside resolve-task works.
  git -C "$TMP" init -q 2>/dev/null
  git -C "$TMP" -c user.email=t@e -c user.name=t commit --allow-empty -q -m init 2>/dev/null

  mkdir -p "$TMP/PERSO/demo/tasks/open" "$TMP/PERSO/demo/tasks/resolved"

  cat > "$TMP/_shared/forge-active" <<EOF
{"session_id":"test-session","project":"demo","started_at":"2026-05-21T13:00:00+0200","tmux_pane":null}
EOF
  export FORGE_CONF_OVERRIDE="$TMP_CONF"
  export COPILOT_SESSION_ID="test-session"
}

teardown() {
  rm -rf "$TMP"
  unset FORGE_CONF_OVERRIDE COPILOT_SESSION_ID TMP TMP_CONF
}

plant_open_task() {
  local path="$1"
  cat > "$path" <<'EOF'
---
created: 2026-04-01
updated: 2026-04-15
project: demo
type: task
status: open
tags: [test]
---

# Test task body
EOF
  git -C "$TMP" add "${path#$TMP/}" 2>/dev/null
  git -C "$TMP" -c user.email=t@e -c user.name=t commit -q -m "plant $path" 2>/dev/null
}

today() { date +%Y-%m-%d; }

# ── Check 1 — happy path: full slug, no pr_spec ─────────────────────────
echo "Check 1 — happy path (full slug, no pr_spec)"
setup
plant_open_task "$TMP/PERSO/demo/tasks/open/2026-05-21-foo-feature.md"
out=$("$FORGE_CONTEXT" resolve-task "2026-05-21-foo-feature" 2>&1)
[ ! -f "$TMP/PERSO/demo/tasks/open/2026-05-21-foo-feature.md" ] \
  && { echo "  ✓ file removed from tasks/open/"; PASS=$((PASS+1)); } \
  || { echo "  ✗ file still in tasks/open/"; FAIL=$((FAIL+1)); }
[ -f "$TMP/PERSO/demo/tasks/resolved/2026-05-21-foo-feature.md" ] \
  && { echo "  ✓ file present in tasks/resolved/"; PASS=$((PASS+1)); } \
  || { echo "  ✗ file missing from tasks/resolved/"; FAIL=$((FAIL+1)); }
grep -q "^status: resolved$" "$TMP/PERSO/demo/tasks/resolved/2026-05-21-foo-feature.md" \
  && { echo "  ✓ status flipped to resolved"; PASS=$((PASS+1)); } \
  || { echo "  ✗ status not flipped"; FAIL=$((FAIL+1)); }
grep -q "^resolved: $(today)$" "$TMP/PERSO/demo/tasks/resolved/2026-05-21-foo-feature.md" \
  && { echo "  ✓ resolved: date inserted"; PASS=$((PASS+1)); } \
  || { echo "  ✗ resolved: date missing"; FAIL=$((FAIL+1)); }
grep -q "^updated: $(today)$" "$TMP/PERSO/demo/tasks/resolved/2026-05-21-foo-feature.md" \
  && { echo "  ✓ updated: date refreshed"; PASS=$((PASS+1)); } \
  || { echo "  ✗ updated: date not refreshed"; FAIL=$((FAIL+1)); }
grep -q "^shipped_via:" "$TMP/PERSO/demo/tasks/resolved/2026-05-21-foo-feature.md" \
  && { echo "  ✗ shipped_via inserted without pr_spec"; FAIL=$((FAIL+1)); } \
  || { echo "  ✓ shipped_via absent when no pr_spec"; PASS=$((PASS+1)); }
teardown

# ── Check 2 — happy path with pr_spec ───────────────────────────────────
echo ""
echo "Check 2 — happy path with sha + pr_spec"
setup
plant_open_task "$TMP/PERSO/demo/tasks/open/2026-05-21-bar-feature.md"
out=$("$FORGE_CONTEXT" resolve-task "2026-05-21-bar-feature" "abc1234567" "shining-cat/forge#13" 2>&1)
grep -q "^shipped_via: shining-cat/forge#13$" "$TMP/PERSO/demo/tasks/resolved/2026-05-21-bar-feature.md" \
  && { echo "  ✓ shipped_via set to pr_spec"; PASS=$((PASS+1)); } \
  || { echo "  ✗ shipped_via missing or wrong"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "abc1234" \
  && { echo "  ✓ short sha in stdout note"; PASS=$((PASS+1)); } \
  || { echo "  ✗ short sha not in stdout"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "shining-cat/forge#13" \
  && { echo "  ✓ pr_spec in stdout note"; PASS=$((PASS+1)); } \
  || { echo "  ✗ pr_spec not in stdout"; FAIL=$((FAIL+1)); }
teardown

# ── Check 3 — no match: refuse with non-zero exit, no movement ──────────
echo ""
echo "Check 3 — no match"
setup
plant_open_task "$TMP/PERSO/demo/tasks/open/2026-05-21-real-task.md"
out=$("$FORGE_CONTEXT" resolve-task "nonexistent-slug" 2>&1)
rc=$?
[ "$rc" -eq 2 ] \
  && { echo "  ✓ exit 2 on no match"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc on no match (expected 2)"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "no open task matching" \
  && { echo "  ✓ warn message present"; PASS=$((PASS+1)); } \
  || { echo "  ✗ warn message missing"; FAIL=$((FAIL+1)); }
[ -f "$TMP/PERSO/demo/tasks/open/2026-05-21-real-task.md" ] \
  && { echo "  ✓ unrelated file untouched"; PASS=$((PASS+1)); } \
  || { echo "  ✗ unrelated file disappeared"; FAIL=$((FAIL+1)); }
teardown

# ── Check 4 — ambiguous exact match: same slug in two projects ──────────
# Under exact matching, ambiguity means the identical slug exists in more
# than one project's tasks/open/ — resolve-task must refuse (exit 2) rather
# than guess which project's task the user meant.
echo ""
echo "Check 4 — ambiguous exact match (same slug, two projects)"
setup
mkdir -p "$TMP/PERSO/other/tasks/open" "$TMP/PERSO/other/tasks/resolved"
plant_open_task "$TMP/PERSO/demo/tasks/open/2026-05-21-dup-task.md"
plant_open_task "$TMP/PERSO/other/tasks/open/2026-05-21-dup-task.md"
out=$("$FORGE_CONTEXT" resolve-task "2026-05-21-dup-task" 2>&1)
rc=$?
[ "$rc" -eq 2 ] \
  && { echo "  ✓ exit 2 on ambiguous match"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc on ambiguous (expected 2)"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "ambiguous" \
  && { echo "  ✓ ambiguity warn present"; PASS=$((PASS+1)); } \
  || { echo "  ✗ ambiguity warn missing"; FAIL=$((FAIL+1)); }
[ -f "$TMP/PERSO/demo/tasks/open/2026-05-21-dup-task.md" ] \
  && [ -f "$TMP/PERSO/other/tasks/open/2026-05-21-dup-task.md" ] \
  && { echo "  ✓ both files untouched"; PASS=$((PASS+1)); } \
  || { echo "  ✗ ambiguous match moved a file"; FAIL=$((FAIL+1)); }
teardown

# ── Check 5 — already resolved: idempotent no-op flip, still moves ──────
echo ""
echo "Check 5 — already status: resolved (idempotent)"
setup
cat > "$TMP/PERSO/demo/tasks/open/2026-05-21-already-done.md" <<'EOF'
---
created: 2026-05-01
status: resolved
resolved: 2026-05-15
project: demo
type: task
---

# Already resolved but stuck in open/
EOF
git -C "$TMP" add "PERSO/demo/tasks/open/2026-05-21-already-done.md" 2>/dev/null
git -C "$TMP" -c user.email=t@e -c user.name=t commit -q -m plant 2>/dev/null

out=$("$FORGE_CONTEXT" resolve-task "2026-05-21-already-done" 2>&1)
[ -f "$TMP/PERSO/demo/tasks/resolved/2026-05-21-already-done.md" ] \
  && { echo "  ✓ file moved to resolved/"; PASS=$((PASS+1)); } \
  || { echo "  ✗ file not moved"; FAIL=$((FAIL+1)); }
grep -q "^resolved: 2026-05-15$" "$TMP/PERSO/demo/tasks/resolved/2026-05-21-already-done.md" \
  && { echo "  ✓ original resolved: date preserved (no pr_spec)"; PASS=$((PASS+1)); } \
  || { echo "  ✗ resolved: date rewritten when it shouldn't be"; FAIL=$((FAIL+1)); }
teardown

# ── Check 6 — substring slug is REFUSED, not resolved ───────────────────
# Substring matching was the footgun: a partial slug must never silently
# resolve a longer-named task. It should refuse (exit 2) and offer the
# near-miss as a hint, leaving the file untouched.
echo ""
echo "Check 6 — substring slug refused with a did-you-mean hint"
setup
plant_open_task "$TMP/PERSO/demo/tasks/open/2026-05-21-uniqueword-feature.md"
out=$("$FORGE_CONTEXT" resolve-task "uniqueword" 2>&1)
rc=$?
[ "$rc" -eq 2 ] \
  && { echo "  ✓ exit 2 on substring-only match"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc on substring-only (expected 2)"; FAIL=$((FAIL+1)); }
[ -f "$TMP/PERSO/demo/tasks/open/2026-05-21-uniqueword-feature.md" ] \
  && { echo "  ✓ substring match left the file untouched"; PASS=$((PASS+1)); } \
  || { echo "  ✗ substring match moved/resolved the file"; FAIL=$((FAIL+1)); }
echo "$out" | grep -qi "did you mean" \
  && echo "$out" | grep -q "2026-05-21-uniqueword-feature" \
  && { echo "  ✓ near-miss offered as a hint"; PASS=$((PASS+1)); } \
  || { echo "  ✗ near-miss hint missing"; FAIL=$((FAIL+1)); }
teardown

# ── Check 7 — across multiple projects: _shared also scanned ────────────
echo ""
echo "Check 7 — _shared/tasks/open/ also scanned"
setup
mkdir -p "$TMP/_shared/tasks/open" "$TMP/_shared/tasks/resolved"
plant_open_task "$TMP/_shared/tasks/open/2026-05-21-shared-task.md"
out=$("$FORGE_CONTEXT" resolve-task "2026-05-21-shared-task" 2>&1)
[ -f "$TMP/_shared/tasks/resolved/2026-05-21-shared-task.md" ] \
  && { echo "  ✓ _shared task resolves to _shared/tasks/resolved/"; PASS=$((PASS+1)); } \
  || { echo "  ✗ _shared task not moved or moved wrong place"; FAIL=$((FAIL+1)); }
teardown

# ── Check 8 — end-to-end: do_post_tool fires on git commit trailer ──────
echo ""
echo "Check 8 — end-to-end (post-tool parses Resolves: trailer)"
setup
# Create a separate repo to commit into (not the vault — the command-line
# `git -C <repo>` form is what do_post_tool looks for).
WORK_REPO="$TMP/repos/demo"
git -C "$WORK_REPO" init -q 2>/dev/null
git -C "$WORK_REPO" -c user.email=t@e -c user.name=t commit --allow-empty -q -m init 2>/dev/null

plant_open_task "$TMP/PERSO/demo/tasks/open/2026-05-21-e2e-task.md"

# Make a real commit in WORK_REPO with the trailer
echo "change" > "$WORK_REPO/file.txt"
git -C "$WORK_REPO" add file.txt
git -C "$WORK_REPO" -c user.email=t@e -c user.name=t commit -q -m "$(cat <<'EOF'
feat: do a thing

Resolves task: 2026-05-21-e2e-task
EOF
)" 2>/dev/null

# Now simulate post-tool firing on the `git -C <path> commit` Bash call
SIM_CMD="git -C $WORK_REPO commit -m something"
STDIN_JSON_PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({
    'tool_name': 'Bash',
    'tool_input': {'command': sys.argv[1]},
    'session_id': 'test-session'
}))
" "$SIM_CMD")

out=$(echo "$STDIN_JSON_PAYLOAD" | "$FORGE_CONTEXT" post-tool 2>&1)
[ -f "$TMP/PERSO/demo/tasks/resolved/2026-05-21-e2e-task.md" ] \
  && { echo "  ✓ e2e trailer parsed, task resolved"; PASS=$((PASS+1)); } \
  || { echo "  ✗ e2e trailer not parsed, task still open"; FAIL=$((FAIL+1)); }
grep -q "^status: resolved$" "$TMP/PERSO/demo/tasks/resolved/2026-05-21-e2e-task.md" 2>/dev/null \
  && { echo "  ✓ e2e: status flipped"; PASS=$((PASS+1)); } \
  || { echo "  ✗ e2e: status not flipped"; FAIL=$((FAIL+1)); }
teardown

# ── Check 9 — post-tool ignores commit without trailer ──────────────────
echo ""
echo "Check 9 — post-tool no-op on commit without Resolves trailer"
setup
WORK_REPO="$TMP/repos/demo"
git -C "$WORK_REPO" init -q 2>/dev/null
git -C "$WORK_REPO" -c user.email=t@e -c user.name=t commit --allow-empty -q -m "plain commit no trailer" 2>/dev/null

plant_open_task "$TMP/PERSO/demo/tasks/open/2026-05-21-untouched.md"
SIM_CMD="git -C $WORK_REPO commit -m foo"
STDIN_JSON_PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({'tool_name': 'Bash', 'tool_input': {'command': sys.argv[1]}, 'session_id': 'test-session'}))
" "$SIM_CMD")
echo "$STDIN_JSON_PAYLOAD" | "$FORGE_CONTEXT" post-tool >/dev/null 2>&1
[ -f "$TMP/PERSO/demo/tasks/open/2026-05-21-untouched.md" ] \
  && { echo "  ✓ no-trailer commit leaves tasks alone"; PASS=$((PASS+1)); } \
  || { echo "  ✗ task moved without a trailer"; FAIL=$((FAIL+1)); }
teardown

# ── Check 10 — post-tool picks up owner/repo#N as shipped_via ───────────
echo ""
echo "Check 10 — post-tool extracts owner/repo#N → shipped_via"
setup
WORK_REPO="$TMP/repos/demo"
git -C "$WORK_REPO" init -q 2>/dev/null
git -C "$WORK_REPO" -c user.email=t@e -c user.name=t commit --allow-empty -q -m init 2>/dev/null

plant_open_task "$TMP/PERSO/demo/tasks/open/2026-05-21-pr-test.md"
echo "x" > "$WORK_REPO/x.txt"; git -C "$WORK_REPO" add x.txt
git -C "$WORK_REPO" -c user.email=t@e -c user.name=t commit -q -m "$(cat <<'EOF'
feat: thing for shining-cat/forge#42

Resolves task: 2026-05-21-pr-test
EOF
)" 2>/dev/null

SIM_CMD="git -C $WORK_REPO commit -m thing"
STDIN_JSON_PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({'tool_name': 'Bash', 'tool_input': {'command': sys.argv[1]}, 'session_id': 'test-session'}))
" "$SIM_CMD")
echo "$STDIN_JSON_PAYLOAD" | "$FORGE_CONTEXT" post-tool >/dev/null 2>&1
grep -q "^shipped_via: shining-cat/forge#42$" "$TMP/PERSO/demo/tasks/resolved/2026-05-21-pr-test.md" 2>/dev/null \
  && { echo "  ✓ shipped_via extracted from commit body"; PASS=$((PASS+1)); } \
  || { echo "  ✗ shipped_via not extracted"; FAIL=$((FAIL+1)); }
teardown

# ── Check 11 — regression: the 2026-07-14 footgun ───────────────────────
# `resolve-task grocy <intended-slug-in-wrong-arg-slot>` once substring-
# matched an unrelated in-progress `…-grocy-feature.md` and mutated + staged
# it. Exact matching must refuse: "grocy" is nobody's exact slug.
echo ""
echo "Check 11 — regression: bare word must not resolve a longer-named task"
setup
cat > "$TMP/PERSO/demo/tasks/open/2026-06-21-grocy-feature-adoption.md" <<'EOF'
---
created: 2026-06-21
updated: 2026-06-21
project: demo
type: task
status: in-progress
tags: [test]
---

# Unrelated in-progress task the user never named
EOF
git -C "$TMP" add "PERSO/demo/tasks/open/2026-06-21-grocy-feature-adoption.md" 2>/dev/null
git -C "$TMP" -c user.email=t@e -c user.name=t commit -q -m plant 2>/dev/null
out=$("$FORGE_CONTEXT" resolve-task "grocy" "2026-06-21-upload-appliance-manuals" 2>&1)
rc=$?
[ "$rc" -eq 2 ] \
  && { echo "  ✓ exit 2 — bare word refused"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc (expected 2)"; FAIL=$((FAIL+1)); }
[ -f "$TMP/PERSO/demo/tasks/open/2026-06-21-grocy-feature-adoption.md" ] \
  && { echo "  ✓ in-progress task untouched in tasks/open/"; PASS=$((PASS+1)); } \
  || { echo "  ✗ in-progress task was moved (the footgun)"; FAIL=$((FAIL+1)); }
grep -q "^status: in-progress$" "$TMP/PERSO/demo/tasks/open/2026-06-21-grocy-feature-adoption.md" 2>/dev/null \
  && { echo "  ✓ status not mutated"; PASS=$((PASS+1)); } \
  || { echo "  ✗ status was mutated"; FAIL=$((FAIL+1)); }
# nothing left staged for a rename
git -C "$TMP" diff --cached --name-only | grep -q "grocy-feature-adoption" \
  && { echo "  ✗ a rename was staged (the footgun)"; FAIL=$((FAIL+1)); } \
  || { echo "  ✓ no rename staged"; PASS=$((PASS+1)); }
teardown

# ── Check 12 — resolved rename left UNSTAGED (vault-sync collision) ──────
# resolve-task must not leave the task-file rename staged: vault-sync (the
# commit mechanism) refuses to run while ANY file is pre-staged, so a staged
# rename blocks the whole ship→resolve→sync flow. The move must land in the
# working tree as D + ?? (unstaged). Task 2026-07-27-resolve-task-vault-sync-staging-collision.
echo ""
echo "Check 12 — resolved rename is left unstaged"
setup
plant_open_task "$TMP/PERSO/demo/tasks/open/2026-05-21-staging-task.md"
out=$("$FORGE_CONTEXT" resolve-task "2026-05-21-staging-task" 2>&1)
[ -f "$TMP/PERSO/demo/tasks/resolved/2026-05-21-staging-task.md" ] \
  && [ ! -f "$TMP/PERSO/demo/tasks/open/2026-05-21-staging-task.md" ] \
  && { echo "  ✓ file moved to resolved/"; PASS=$((PASS+1)); } \
  || { echo "  ✗ file not moved"; FAIL=$((FAIL+1)); }
staged=$(git -C "$TMP" diff --cached --name-only 2>/dev/null)
[ -z "$staged" ] \
  && { echo "  ✓ nothing left staged in the index"; PASS=$((PASS+1)); } \
  || { echo "  ✗ index left dirty: $staged"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
