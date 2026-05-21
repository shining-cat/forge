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
  export CLAUDE_CODE_SESSION_ID="test-session"
}

teardown() {
  rm -rf "$TMP"
  unset FORGE_CONF_OVERRIDE CLAUDE_CODE_SESSION_ID TMP TMP_CONF
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

# ── Check 3 — no match: warn-only, no movement, exit 0 ──────────────────
echo ""
echo "Check 3 — no match"
setup
plant_open_task "$TMP/PERSO/demo/tasks/open/2026-05-21-real-task.md"
out=$("$FORGE_CONTEXT" resolve-task "nonexistent-slug" 2>&1)
rc=$?
[ "$rc" -eq 0 ] \
  && { echo "  ✓ exit 0 on no match"; PASS=$((PASS+1)); } \
  || { echo "  ✗ exit $rc on no match (expected 0)"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "no open task matching" \
  && { echo "  ✓ warn message present"; PASS=$((PASS+1)); } \
  || { echo "  ✗ warn message missing"; FAIL=$((FAIL+1)); }
[ -f "$TMP/PERSO/demo/tasks/open/2026-05-21-real-task.md" ] \
  && { echo "  ✓ unrelated file untouched"; PASS=$((PASS+1)); } \
  || { echo "  ✗ unrelated file disappeared"; FAIL=$((FAIL+1)); }
teardown

# ── Check 4 — ambiguous match: warn, no movement ────────────────────────
echo ""
echo "Check 4 — ambiguous match (>1 file)"
setup
plant_open_task "$TMP/PERSO/demo/tasks/open/2026-05-21-foo-one.md"
plant_open_task "$TMP/PERSO/demo/tasks/open/2026-05-22-foo-two.md"
out=$("$FORGE_CONTEXT" resolve-task "foo" 2>&1)
echo "$out" | grep -q "ambiguous" \
  && { echo "  ✓ ambiguity warn present"; PASS=$((PASS+1)); } \
  || { echo "  ✗ ambiguity warn missing"; FAIL=$((FAIL+1)); }
[ -f "$TMP/PERSO/demo/tasks/open/2026-05-21-foo-one.md" ] \
  && [ -f "$TMP/PERSO/demo/tasks/open/2026-05-22-foo-two.md" ] \
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

# ── Check 6 — slug suffix-only match (no date prefix) ───────────────────
echo ""
echo "Check 6 — substring slug match (no date prefix)"
setup
plant_open_task "$TMP/PERSO/demo/tasks/open/2026-05-21-uniqueword-feature.md"
out=$("$FORGE_CONTEXT" resolve-task "uniqueword" 2>&1)
[ -f "$TMP/PERSO/demo/tasks/resolved/2026-05-21-uniqueword-feature.md" ] \
  && { echo "  ✓ substring slug match resolves"; PASS=$((PASS+1)); } \
  || { echo "  ✗ substring match failed"; FAIL=$((FAIL+1)); }
teardown

# ── Check 7 — across multiple projects: _shared also scanned ────────────
echo ""
echo "Check 7 — _shared/tasks/open/ also scanned"
setup
mkdir -p "$TMP/_shared/tasks/open" "$TMP/_shared/tasks/resolved"
plant_open_task "$TMP/_shared/tasks/open/2026-05-21-shared-task.md"
out=$("$FORGE_CONTEXT" resolve-task "shared-task" 2>&1)
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

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
