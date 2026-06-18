#!/usr/bin/env bash
# Tests forge-context.sh gate subcommand — compound-rejection postscript
#
# Regression guard for 2026-06-08-commit-failure-unstages-files.md: when a
# Builder dispatches `git add … && git commit …` as one Bash compound and the
# Keeper PreToolUse gate denies it (stale checkpoint), the ENTIRE compound is
# rejected — neither half runs. Pre-fix, the deny reason didn't say so, and
# subagent Builders retried only `git commit`, which failed silently ("no
# changes added to commit") because the index was still empty.
#
# Fix: when the denied command contains `git add`, the deny reason appends a
# postscript: "re-run the WHOLE command, not just the trailing `git commit`".
# Plain `git commit` denies don't get the postscript.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_CONTEXT="$SCRIPT_DIR/../forge-context.sh"

PASS=0; FAIL=0

setup_stale_session() {
  TMP=$(mktemp -d)
  # Vault skeleton
  mkdir -p "$TMP/_shared" "$TMP/PERSO/forge"
  # Marker pointing to PERSO/forge with a known session_id
  cat > "$TMP/_shared/forge-active" <<'EOF'
{"session_id":"test-session-gate","project":"forge","started_at":"2026-05-20T10:00:00+0200","tmux_pane":null}
EOF
  # Stale checkpoint — backdate mtime to 2h ago so age > 15min threshold.
  # NOTE: get_checkpoint_age_minutes returns min(raw_age, gap-since-last-signal)
  # where the gap script reads mtimes of the marker AND any checkpoint/braindump.
  # If we leave the marker mtime "now", gap=0 and the age is clamped to 0,
  # bypassing the deny. So backdate every file that contributes a signal.
  echo "stale" > "$TMP/PERSO/forge/current-checkpoint.md"
  local stale_stamp
  stale_stamp="$(date -v-2H '+%Y%m%d%H%M' 2>/dev/null || date -d '2 hours ago' '+%Y%m%d%H%M')"
  touch -t "$stale_stamp" "$TMP/PERSO/forge/current-checkpoint.md" \
    "$TMP/_shared/forge-active"
  # Mock forge.conf
  TMP_CONF="$TMP/forge.conf"
  printf 'VAULT_PATH=%s\nREPO_ROOTS=%s\n' "$TMP" "$TMP" > "$TMP_CONF"
  export FORGE_CONF_OVERRIDE="$TMP_CONF"
  # Make session_owns_forge pass (helper reads CLAUDE_CODE_SESSION_ID OR the
  # session_id field of the stdin JSON we pipe in).
  export CLAUDE_CODE_SESSION_ID="test-session-gate"
}

teardown() {
  rm -rf "$TMP"
  unset FORGE_CONF_OVERRIDE CLAUDE_CODE_SESSION_ID TMP TMP_CONF
}

# Build a Claude Code PreToolUse JSON envelope for a given Bash command.
build_hook_input() {
  local cmd="$1"
  jq -nc --arg cmd "$cmd" '{
    session_id: "test-session-gate",
    tool_name: "Bash",
    tool_input: { command: $cmd }
  }'
}

echo "Check 1 — denied compound containing \`git add\` carries the postscript"
setup_stale_session
input=$(build_hook_input "git -C /tmp/repo add foo.md && git -C /tmp/repo commit -m 'bar'")
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
if printf '%s' "$reason" | grep -qF "stale"; then
  echo "  ✓ existing staleness wording preserved"; PASS=$((PASS+1))
else
  echo "  ✗ staleness phrasing lost (got: $reason)"; FAIL=$((FAIL+1))
fi
if printf '%s' "$reason" | grep -qF "re-run the WHOLE command"; then
  echo "  ✓ postscript present when command contains \`git add\`"; PASS=$((PASS+1))
else
  echo "  ✗ postscript missing (got: $reason)"; FAIL=$((FAIL+1))
fi
teardown

echo ""
echo "Check 2 — denied bare \`git commit\` does NOT carry the postscript"
setup_stale_session
input=$(build_hook_input "git -C /tmp/repo commit -m 'bar'")
out=$(printf '%s' "$input" | "$FORGE_CONTEXT" gate 2>/dev/null)
rc=$?
[ "$rc" = "0" ] && { echo "  ✓ gate exited 0"; PASS=$((PASS+1)); } \
  || { echo "  ✗ gate exited $rc"; FAIL=$((FAIL+1)); }
reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if printf '%s' "$reason" | grep -qF "stale"; then
  echo "  ✓ staleness wording present (regression guard)"; PASS=$((PASS+1))
else
  echo "  ✗ staleness wording missing (got: $reason)"; FAIL=$((FAIL+1))
fi
if printf '%s' "$reason" | grep -qvF "re-run the WHOLE command"; then
  echo "  ✓ postscript absent for bare \`git commit\` (no regression of simple case)"; PASS=$((PASS+1))
else
  echo "  ✗ postscript leaked into bare-commit deny (got: $reason)"; FAIL=$((FAIL+1))
fi
teardown

echo ""
echo "Check 3 — stale checkpoint + VAULT-targeted commit → NO deny (vault exclusion)"
setup_stale_session
# VAULT_PATH is $TMP in this harness; a commit targeting a path under it is
# vault bookkeeping and must skip the stale-checkpoint deny.
input=$(build_hook_input "git -C $TMP/PERSO/forge add . && git -C $TMP/PERSO/forge commit -m 'checkpoint bookkeeping'")
out=$(printf '%s' "$input" | "$FORGE_CONTEXT" gate 2>/dev/null)
if [ -z "$out" ]; then
  echo "  ✓ vault-targeted commit not denied despite stale checkpoint"; PASS=$((PASS+1))
else
  echo "  ✗ vault commit was denied (got: $out)"; FAIL=$((FAIL+1))
fi
# Control: a code-repo commit (outside VAULT_PATH) under the same stale state still denies.
input=$(build_hook_input "git -C /tmp/some-code-repo commit -m 'x'")
out=$(printf '%s' "$input" | "$FORGE_CONTEXT" gate 2>/dev/null)
if [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" = "deny" ]; then
  echo "  ✓ control: non-vault code-repo commit still denied (stale guard intact)"; PASS=$((PASS+1))
else
  echo "  ✗ control: non-vault commit should still deny (got: $out)"; FAIL=$((FAIL+1))
fi
teardown

echo ""
echo "── Total: $PASS pass, $FAIL fail ──"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
