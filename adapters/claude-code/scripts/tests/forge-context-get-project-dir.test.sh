#!/usr/bin/env bash
# Tests forge-context.sh get_project_dir function.
#
# Critical contract assertion: on miss, get_project_dir returns 0 with empty
# stdout (NOT 1). The non-zero exit caused PreToolUse/PostToolUse hook spam
# on every Bash tool call for greenfield Forge projects that have no repo
# under REPO_ROOTS yet. See task: 2026-06-06-greenfield-project-hook-spam.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_CONTEXT="$SCRIPT_DIR/../forge-context.sh"

PASS=0; FAIL=0

setup() {
  TMP=$(mktemp -d)
  TMP_CONF="$TMP/forge.conf"
  # REPO_ROOTS points at a workspace that may or may not contain the project.
  mkdir -p "$TMP/workspace"
  cat > "$TMP_CONF" <<EOF
VAULT_PATH=$TMP
REPO_ROOTS=$TMP/workspace
EOF
  export FORGE_CONF_OVERRIDE="$TMP_CONF"
  # Unique session id per setup so the warn-once marker doesn't carry over
  # between checks (markers live in /tmp keyed by session id).
  export CLAUDE_CODE_SESSION_ID="get-project-dir-test-$$-$RANDOM"
  WARN_MARKER="/tmp/forge-context-warned-${CLAUDE_CODE_SESSION_ID}"
  # Source the script so we can call the function directly. The script
  # returns early at the sourceable boundary when BASH_SOURCE != $0.
  # shellcheck disable=SC1090
  source "$FORGE_CONTEXT"
}

teardown() {
  rm -rf "$TMP"
  rm -f "$WARN_MARKER"
  unset FORGE_CONF_OVERRIDE CLAUDE_CODE_SESSION_ID TMP TMP_CONF WARN_MARKER
}

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then echo "  ✓ $name"; PASS=$((PASS+1));
  else echo "  ✗ $name — expected '$expected', got '$actual'"; FAIL=$((FAIL+1)); fi
}

echo "Check 1 — hit case: project exists under REPO_ROOTS → exit 0 with path"
setup
mkdir -p "$TMP/workspace/myproj"
out="$(get_project_dir myproj)"
rc=$?
assert_eq "exit 0 on hit" "0" "$rc"
assert_eq "stdout is absolute project path" "$TMP/workspace/myproj" "$out"
teardown

echo ""
echo "Check 2 — miss case (the regression): no matching project → exit 0, empty stdout"
setup
# No project subdir created under workspace/
out="$(get_project_dir ghostproj 2>/dev/null)"
rc=$?
assert_eq "exit 0 on miss (warn-don't-exit contract)" "0" "$rc"
assert_eq "stdout is empty on miss" "" "$out"
teardown

echo ""
echo "Check 3 — warn-once preserved: first miss emits warn, second miss is silent"
setup
err1="$(get_project_dir ghostproj 2>&1 >/dev/null)"
err2="$(get_project_dir ghostproj 2>&1 >/dev/null)"
if printf '%s' "$err1" | grep -q "no project repo found for 'ghostproj'"; then
  echo "  ✓ first call emits warn to stderr"; PASS=$((PASS+1));
else
  echo "  ✗ first call did NOT emit warn (got: $err1)"; FAIL=$((FAIL+1));
fi
if [ -z "$err2" ]; then
  echo "  ✓ second call silent (warn-once marker honored)"; PASS=$((PASS+1));
else
  echo "  ✗ second call re-emitted warn (got: $err2)"; FAIL=$((FAIL+1));
fi
teardown

echo ""
echo "Check 4 — env-nested layout (ROOT/env/project/) still resolves"
setup
mkdir -p "$TMP/workspace/PERSO/nestedproj"
out="$(get_project_dir nestedproj)"
rc=$?
assert_eq "exit 0 on nested hit" "0" "$rc"
assert_eq "stdout is nested project path" "$TMP/workspace/PERSO/nestedproj" "$out"
teardown

echo ""
echo "── Total: $PASS pass, $FAIL fail ──"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
