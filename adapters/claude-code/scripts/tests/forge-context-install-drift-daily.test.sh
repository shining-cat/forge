#!/usr/bin/env bash
# Tests the daily mid-session install-drift note in do_post_tool
# (2026-06-05-versioning-and-changelog, repurposed).
#
# maybe_daily_install_drift_note: when FORGE_REPO is behind its upstream and the
# once-per-day throttle is open, do_post_tool emits a "N behind upstream" note.
# Throttled (second call same day → silent). Skips in subagents. Hermetic — uses
# a local bare repo as the remote, so `git fetch` needs no network.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../forge-context.sh"
PASS=0; FAIL=0

assert_contains() {
  local name="$1" needle="$2" hay="$3"
  if echo "$hay" | grep -qF "$needle"; then echo "  ✓ $name"; PASS=$((PASS+1));
  else echo "  ✗ $name — '$hay' lacked '$needle'"; FAIL=$((FAIL+1)); fi
}
assert_not_contains() {
  local name="$1" needle="$2" hay="$3"
  if echo "$hay" | grep -qF "$needle"; then echo "  ✗ $name — unexpectedly found '$needle'"; FAIL=$((FAIL+1));
  else echo "  ✓ $name"; PASS=$((PASS+1)); fi
}

gitq() { git -c user.email=t@e -c user.name=t -c commit.gpgsign=false "$@" >/dev/null 2>&1; }

setup() {
  TMP=$(mktemp -d)
  # Local bare "remote".
  gitq init --bare "$TMP/remote.git"
  # Seed clone → first commit → push (establishes main).
  gitq clone "$TMP/remote.git" "$TMP/seed"
  echo v1 > "$TMP/seed/f"; gitq -C "$TMP/seed" add f; gitq -C "$TMP/seed" commit -m c1
  gitq -C "$TMP/seed" push -u origin HEAD:main
  # FORGE_REPO clone — at c1, tracking origin/main.
  gitq clone "$TMP/remote.git" "$TMP/forge"
  gitq -C "$TMP/forge" branch --set-upstream-to=origin/main 2>/dev/null || true

  # Vault + marker (session-owned so do_post_tool's session gate passes).
  mkdir -p "$TMP/vault/_shared" "$TMP/vault/PERSO/test-proj"
  printf '{"session_id":"s","project":"test-proj","started_at":"x","tmux_pane":null}' > "$TMP/vault/_shared/forge-active"
  TMP_CONF="$TMP/forge.conf"
  { echo "VAULT_PATH=$TMP/vault"; echo "FORGE_REPO=$TMP/forge"; } > "$TMP_CONF"
  export FORGE_CONF_OVERRIDE="$TMP_CONF"
  export CLAUDE_CODE_SESSION_ID="s"
  rm -f /tmp/forge-drift-daily-check       # open the throttle for the test
}
teardown() { rm -rf "$TMP"; rm -f /tmp/forge-drift-daily-check; unset FORGE_CONF_OVERRIDE CLAUDE_CODE_SESSION_ID TMP TMP_CONF; }

# Advance the remote by one commit so the FORGE_REPO clone is behind after fetch.
advance_remote() {
  echo v2 > "$TMP/seed/f"; gitq -C "$TMP/seed" commit -am c2; gitq -C "$TMP/seed" push origin HEAD:main
}

post_tool() {
  local agent="${1:-}"
  local json
  if [ -n "$agent" ]; then
    json=$(jq -nc --arg a "$agent" '{session_id:"s",agent_id:$a,tool_name:"Read",tool_input:{file_path:"/x"}}')
  else
    json=$(jq -nc '{session_id:"s",tool_name:"Read",tool_input:{file_path:"/x"}}')
  fi
  printf '%s' "$json" | "$SCRIPT" post-tool 2>/dev/null
}

echo "=== daily install-drift note (do_post_tool) ==="

# 1. Behind + throttle open → note emitted
setup
advance_remote
out=$(post_tool)
assert_contains "behind → drift note emitted" "behind upstream" "$out"
assert_contains "note carries the commit count (1)" "1 commit(s) behind" "$out"
teardown

# 2. Throttle: a second call the same day is silent (marker stamped)
setup
advance_remote
post_tool >/dev/null            # first call stamps the marker
out=$(post_tool)               # second call same day
assert_not_contains "second same-day call → no drift note (throttled)" "behind upstream" "$out"
teardown

# 3. In sync → no note (and stamps marker, no spurious output)
setup
out=$(post_tool)               # forge clone == remote, nothing behind
assert_not_contains "in-sync → no drift note" "behind upstream" "$out"
teardown

# 4. Subagent (agent_id set) → no drift note even when behind + throttle open
setup
advance_remote
out=$(post_tool "subagent-123")
assert_not_contains "subagent dispatch → no drift note" "behind upstream" "$out"
teardown

echo ""
echo "── Total: $PASS pass, $FAIL fail ──"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
