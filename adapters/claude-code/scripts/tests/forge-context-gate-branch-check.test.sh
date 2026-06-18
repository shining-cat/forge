#!/usr/bin/env bash
# Tests forge-context.sh gate — branch-discipline check (2026-06-05-pre-commit-branch-check-pattern)
#
# When the checkpoint is FRESH (so the stale-deny doesn't preempt), committing
# directly onto main/master in a code repo under REPO_ROOTS should emit an
# "ask" decision — EXCEPT the vault (committing to vault main is normal) and
# repos outside REPO_ROOTS. Feature branches never prompt.
#
# Decision is "ask", not "deny" — the escape hatch for legitimate hotfix commits.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_CONTEXT="$SCRIPT_DIR/../forge-context.sh"

PASS=0; FAIL=0

# Build a code/vault git repo at $1 on branch $2 with one staged file (unless $3=nostage).
make_repo() {
  local dir="$1" branch="$2" stage="${3:-stage}"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" symbolic-ref HEAD "refs/heads/$branch"
  git -C "$dir" config user.email t@t.t >/dev/null 2>&1
  git -C "$dir" config user.name t >/dev/null 2>&1
  echo seed > "$dir/seed.txt"
  if [ "$stage" = "stage" ]; then
    git -C "$dir" add seed.txt
  fi
}

setup() {
  TMP=$(mktemp -d)
  VAULT="$TMP/vault"
  mkdir -p "$VAULT/_shared" "$VAULT/PERSO/forge"
  cat > "$VAULT/_shared/forge-active" <<'EOF'
{"session_id":"test-branch-gate","project":"forge","started_at":"2026-06-18T10:00:00+0200","tmux_pane":null}
EOF
  # FRESH checkpoint (touched now → age ~0 → stale-deny does not fire).
  echo "fresh" > "$VAULT/PERSO/forge/current-checkpoint.md"

  # REPO_ROOTS = $TMP (contains the vault AND code repos, mirroring reality).
  TMP_CONF="$TMP/forge.conf"
  printf 'VAULT_PATH=%s\nREPO_ROOTS=%s\n' "$VAULT" "$TMP" > "$TMP_CONF"
  export FORGE_CONF_OVERRIDE="$TMP_CONF"
  export CLAUDE_CODE_SESSION_ID="test-branch-gate"

  make_repo "$TMP/myapp" main            # code repo on main, staged
  make_repo "$TMP/myapp-feat" feature-x  # code repo on a feature branch, staged
  make_repo "$TMP/myapp-clean" main nostage  # code repo on main, nothing staged
  make_repo "$VAULT" main                # vault root is a git repo on main, staged
  OUT_REPO="$TMP-external/ext"
  make_repo "$OUT_REPO" main             # repo OUTSIDE REPO_ROOTS, on main, staged
}

teardown() {
  rm -rf "$TMP" "$TMP-external"
  unset FORGE_CONF_OVERRIDE CLAUDE_CODE_SESSION_ID TMP VAULT TMP_CONF OUT_REPO
}

hook_input() { jq -nc --arg c "$1" '{session_id:"test-branch-gate",tool_name:"Bash",tool_input:{command:$c}}'; }

decision() {
  local out; out="$(printf '%s' "$1" | "$FORGE_CONTEXT" gate 2>/dev/null)"
  [ -z "$out" ] && { echo "allow"; return; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null
}

check() {
  local name="$1" expected="$2" cmd="$3"
  local got; got="$(decision "$(hook_input "$cmd")")"
  if [ "$got" = "$expected" ]; then echo "  ✓ $name"; PASS=$((PASS+1));
  else echo "  ✗ $name — expected '$expected', got '$got'"; FAIL=$((FAIL+1)); fi
}

setup
echo "=== gate branch-discipline check ==="
check "git -C code-repo on main → ask"            ask   "git -C $TMP/myapp commit -m x"
check "cd code-repo && commit on main → ask"      ask   "cd $TMP/myapp && git commit -m x"
check "feature branch → allow"                    allow "git -C $TMP/myapp-feat commit -m x"
check "code-repo on main, nothing staged → allow" allow "git -C $TMP/myapp-clean commit -m x"
check "commit -am auto-stage on main → ask"       ask   "git -C $TMP/myapp-clean commit -am x"
check "vault on main (excluded) → allow"          allow "git -C $VAULT commit -m x"
check "repo outside REPO_ROOTS → allow"           allow "git -C $OUT_REPO commit -m x"
check "bare git commit (cwd unknown) → allow"     allow "git commit -m x"
check "non-commit command → allow"                allow "git -C $TMP/myapp status"
teardown

echo ""
echo "── Total: $PASS pass, $FAIL fail ──"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
