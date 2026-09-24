#!/usr/bin/env bash
# Tests forge-context.sh gate subcommand — compound-rejection postscript
#
# Regression guard for 2026-06-08-commit-failure-unstages-files.md: when a
# Builder dispatches `git add … && git commit …` as one Bash compound and the
# Keeper PreToolUse gate denies it, the ENTIRE compound is rejected — neither
# half runs. Pre-fix, the deny reason didn't say so, and subagent Builders
# retried only `git commit`, which failed silently ("no changes added to
# commit") because the index was still empty.
#
# Fix: when the denied command contains `git add`, the deny reason appends a
# postscript: "re-run the WHOLE command, not just the trailing `git commit`".
# Plain `git commit` denies don't get the postscript.
#
# NOTE: as of 2026-08-03-delta-aware-checkpoint-pressure the gate denies on a
# COMMIT COUNT (>= COMMIT_GATE_MAX_UNLOGGED commits since the checkpoint mtime),
# not on raw checkpoint wall-clock age. So the deny is triggered here by stacking
# commits in the target repo, and the reason wording is "commits since the last
# checkpoint refresh" (not "stale"). The postscript + vault-exclusion behaviour
# under test is unchanged.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_CONTEXT="$SCRIPT_DIR/../forge-context.sh"

PASS=0; FAIL=0

# Phrasing the count-based deny reason must contain (see do_gate).
DENY_PHRASE="commits since the last checkpoint refresh"

setup_gated_session() {
  TMP=$(mktemp -d)
  # Vault is a SUBDIR of $TMP; code repos are siblings under $TMP (= REPO_ROOTS).
  # This keeps the code repo OUT of VAULT_PATH so the vault-exclusion doesn't
  # swallow it (a code repo under VAULT_PATH would be treated as bookkeeping).
  VAULT="$TMP/vault"
  mkdir -p "$VAULT/_shared" "$VAULT/PERSO/forge"
  # Marker pointing to PERSO/forge with a known session_id
  cat > "$VAULT/_shared/forge-active" <<'EOF'
{"session_id":"test-session-gate","project":"forge","started_at":"2026-05-20T10:00:00+0200","tmux_pane":null}
EOF
  # Checkpoint backdated 1h so the code-repo commits made "now" all count as
  # authored after it (git log --since="@<ckpt_mtime>").
  echo "ckpt" > "$VAULT/PERSO/forge/current-checkpoint.md"
  local past
  past="$(date -v-1H '+%Y%m%d%H%M' 2>/dev/null || date -d '1 hour ago' '+%Y%m%d%H%M')"
  touch -t "$past" "$VAULT/PERSO/forge/current-checkpoint.md"
  # Mock forge.conf — REPO_ROOTS=$TMP contains both the vault and code repos
  # (mirrors reality). COMMIT_GATE_MAX_UNLOGGED left at its built-in default 5.
  TMP_CONF="$TMP/forge.conf"
  printf 'VAULT_PATH=%s\nREPO_ROOTS=%s\n' "$VAULT" "$TMP" > "$TMP_CONF"
  export FORGE_CONF_OVERRIDE="$TMP_CONF"
  # Make session_owns_forge pass (helper reads COPILOT_SESSION_ID OR the
  # session_id field of the stdin JSON we pipe in).
  export COPILOT_SESSION_ID="test-session-gate"

  # Code repo with 6 commits (>= default COMMIT_GATE_MAX_UNLOGGED=5), all
  # authored after the backdated checkpoint mtime → count-based deny fires.
  CODE="$TMP/code-repo"
  mkdir -p "$CODE"
  git -C "$CODE" init -q
  git -C "$CODE" config user.email t@t.t >/dev/null 2>&1
  git -C "$CODE" config user.name t >/dev/null 2>&1
  local i
  for i in 1 2 3 4 5 6; do
    echo "$i" > "$CODE/f$i.txt"
    git -C "$CODE" add "f$i.txt"
    git -C "$CODE" commit -qm "c$i"
  done
}

teardown() {
  rm -rf "$TMP"
  unset FORGE_CONF_OVERRIDE COPILOT_SESSION_ID TMP VAULT TMP_CONF CODE
}

# Build a GitHub Copilot CLI PreToolUse JSON envelope for a given Bash command.
build_hook_input() {
  local cmd="$1"
  jq -nc --arg cmd "$cmd" '{
    session_id: "test-session-gate",
    tool_name: "Bash",
    tool_input: { command: $cmd }
  }'
}

echo "Check 1 — denied compound containing \`git add\` carries the postscript"
setup_gated_session
input=$(build_hook_input "git -C $CODE add foo.md && git -C $CODE commit -m 'bar'")
out=$(printf '%s' "$input" | "$FORGE_CONTEXT" gate 2>/dev/null)
rc=$?
[ "$rc" = "0" ] && { echo "  ✓ gate exited 0 (deny emitted via JSON, not exit code)"; PASS=$((PASS+1)); } \
  || { echo "  ✗ gate exited $rc"; FAIL=$((FAIL+1)); }
# JSON-parse the emitted reason
reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ -n "$reason" ]; then
  echo "  ✓ deny emits parseable JSON with permissionDecisionReason"; PASS=$((PASS+1))
else
  echo "  ✗ deny JSON missing/invalid (got: $out)"; FAIL=$((FAIL+1))
fi
if printf '%s' "$reason" | grep -qF "$DENY_PHRASE"; then
  echo "  ✓ count-based deny wording present"; PASS=$((PASS+1))
else
  echo "  ✗ deny phrasing lost (got: $reason)"; FAIL=$((FAIL+1))
fi
if printf '%s' "$reason" | grep -qF "re-run the WHOLE command"; then
  echo "  ✓ postscript present when command contains \`git add\`"; PASS=$((PASS+1))
else
  echo "  ✗ postscript missing (got: $reason)"; FAIL=$((FAIL+1))
fi
teardown

echo ""
echo "Check 2 — denied bare \`git commit\` does NOT carry the postscript"
setup_gated_session
input=$(build_hook_input "git -C $CODE commit -m 'bar'")
out=$(printf '%s' "$input" | "$FORGE_CONTEXT" gate 2>/dev/null)
rc=$?
[ "$rc" = "0" ] && { echo "  ✓ gate exited 0"; PASS=$((PASS+1)); } \
  || { echo "  ✗ gate exited $rc"; FAIL=$((FAIL+1)); }
reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if printf '%s' "$reason" | grep -qF "$DENY_PHRASE"; then
  echo "  ✓ count-based deny wording present (regression guard)"; PASS=$((PASS+1))
else
  echo "  ✗ deny wording missing (got: $reason)"; FAIL=$((FAIL+1))
fi
if printf '%s' "$reason" | grep -qvF "re-run the WHOLE command"; then
  echo "  ✓ postscript absent for bare \`git commit\` (no regression of simple case)"; PASS=$((PASS+1))
else
  echo "  ✗ postscript leaked into bare-commit deny (got: $reason)"; FAIL=$((FAIL+1))
fi
teardown

echo ""
echo "Check 3 — VAULT-targeted commit → NO deny (vault exclusion)"
setup_gated_session
# VAULT_PATH is $VAULT here; a commit targeting a path under it is vault
# bookkeeping and must skip the deny regardless of commit count.
input=$(build_hook_input "git -C $VAULT/PERSO/forge add . && git -C $VAULT/PERSO/forge commit -m 'checkpoint bookkeeping'")
out=$(printf '%s' "$input" | "$FORGE_CONTEXT" gate 2>/dev/null)
if [ -z "$out" ]; then
  echo "  ✓ vault-targeted commit not denied"; PASS=$((PASS+1))
else
  echo "  ✗ vault commit was denied (got: $out)"; FAIL=$((FAIL+1))
fi
# Control: a code-repo commit (outside VAULT_PATH) with the same stacked commits still denies.
input=$(build_hook_input "git -C $CODE commit -m 'x'")
out=$(printf '%s' "$input" | "$FORGE_CONTEXT" gate 2>/dev/null)
if [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" = "deny" ]; then
  echo "  ✓ control: non-vault code-repo commit still denied (count guard intact)"; PASS=$((PASS+1))
else
  echo "  ✗ control: non-vault commit should still deny (got: $out)"; FAIL=$((FAIL+1))
fi
teardown

echo ""
echo "Check 4 — deny reason tells the user to checkpoint in a SEPARATE Bash call"
# Regression guard for 2026-07-27-commit-gate-message-separate-checkpoint-call:
# the natural one-liner chains `forge-context.sh write-checkpoint … && git commit`,
# but PreToolUse deny rejects the WHOLE compound before write-checkpoint runs, so
# "re-run the WHOLE command" loops forever. The base message must state the
# checkpoint write has to be a SEPARATE Bash call from the commit. This applies to
# every count-based deny, so a bare `git commit` deny is enough to assert it.
setup_gated_session
input=$(build_hook_input "git -C $CODE commit -m 'bar'")
out=$(printf '%s' "$input" | "$FORGE_CONTEXT" gate 2>/dev/null)
reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if printf '%s' "$reason" | grep -qiF "separate Bash call"; then
  echo "  ✓ separate-Bash-call guidance present"; PASS=$((PASS+1))
else
  echo "  ✗ separate-call guidance missing (got: $reason)"; FAIL=$((FAIL+1))
fi
teardown

echo ""
echo "── Total: $PASS pass, $FAIL fail ──"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
