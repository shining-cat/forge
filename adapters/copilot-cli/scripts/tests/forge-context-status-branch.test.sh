#!/usr/bin/env bash
# Test runner for forge-context.sh status branch chip: worktree-aware, no guessing.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../forge-context.sh"
PASS=0; FAIL=0
assert_contains() { local n="$1" needle="$2" hay="$3"
  if echo "$hay" | grep -qF "$needle"; then echo "  ✓ $n"; PASS=$((PASS+1))
  else echo "  ✗ $n — missing: $needle"; echo "    Got: $hay"; FAIL=$((FAIL+1)); fi; }
assert_not_contains() { local n="$1" needle="$2" hay="$3"
  if echo "$hay" | grep -qF "$needle"; then echo "  ✗ $n — unexpected: $needle"; echo "    Got: $hay"; FAIL=$((FAIL+1))
  else echo "  ✓ $n"; PASS=$((PASS+1)); fi; }

T=$(mktemp -d)
V="$T/vault"; R="$T/repos"
mkdir -p "$V/_shared" "$V/PERSO/demo" "$R/demo"
printf -- '---\ndate: 2026-10-29\nproject: demo\nsession: open\n---\n' > "$V/PERSO/demo/current-checkpoint.md"
printf '{"session_id":"s1","project":"demo","started_at":"2026-10-29T09:00:00+0100","tmux_pane":null}' > "$V/_shared/forge-active"
printf 'VAULT_PATH=%s\nREPO_ROOTS=%s\n' "$V" "$R" > "$T/forge.conf"

git -C "$R/demo" init -q -b main
git -C "$R/demo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$R/demo" worktree add -q -b feature-x "$T/demo-wt"
mkdir -p "$T/unrelated"; git -C "$T/unrelated" init -q -b other
git -C "$T/unrelated" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

status_for() { # $1 = cwd
  printf '{"session_id":"s1","workspace":{"current_dir":"%s"}}' "$1" \
    | env -u COPILOT_SESSION_ID -u COPILOT_AGENT_SESSION_ID FORGE_CONF_OVERRIDE="$T/forge.conf" "$SCRIPT" status 2>/dev/null
}

echo "=== status branch chip ==="
assert_contains "cwd in main checkout shows main" "🌿 main" "$(status_for "$R/demo")"
assert_contains "cwd in worktree shows worktree branch" "🌿 feature-x" "$(status_for "$T/demo-wt")"
assert_contains "worktree branch follows checkout" "🌿 feature-y" \
  "$(git -C "$T/demo-wt" checkout -q -b feature-y && status_for "$T/demo-wt")"
assert_contains "unrelated cwd falls back to project dir" "🌿 main" "$(status_for "$T/unrelated")"
assert_not_contains "unrelated repo branch never leaks" "🌿 other" "$(status_for "$T/unrelated")"
assert_contains "null current_dir falls back without error" "🌿" \
  "$(printf '{"session_id":"s1","workspace":{"current_dir":null}}' | env -u COPILOT_SESSION_ID -u COPILOT_AGENT_SESSION_ID FORGE_CONF_OVERRIDE="$T/forge.conf" "$SCRIPT" status 2>/dev/null)"

rm -rf "$T"
echo "Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ]
