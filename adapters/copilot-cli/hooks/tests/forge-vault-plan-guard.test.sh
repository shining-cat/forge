#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_FILE="$SCRIPT_DIR/../forge-vault-plan-guard.sh"
TMP_HOME="$(mktemp -d)"
TMP_VAULT="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME" "$TMP_VAULT"' EXIT
mkdir -p "$TMP_HOME/.copilot/scripts" "$TMP_VAULT/_shared"
printf 'VAULT_PATH=%s\n' "$TMP_VAULT" > "$TMP_HOME/.copilot/forge.conf"
printf '%s' '{"session_id":"test","project":"forge"}' > "$TMP_VAULT/_shared/forge-active"
cat > "$TMP_HOME/.copilot/scripts/forge-context.sh" <<'SH'
extract_marker_project() { if [ -s "$MARKER" ]; then printf 'forge'; fi; }
get_vault_dir() { printf '%s' "$HOME/.copilot"; }
SH

PASS=0
FAIL=0
check() {
  local name="$1" expected="$2" input="$3" output rc actual
  output="$(printf '%s\n' "$input" | HOME="$TMP_HOME" bash "$HOOK_FILE")"
  rc=$?
  actual="$(printf '%s\n' "$output" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null)"
  [ -z "$actual" ] && actual="allow"
  if [ "$rc" -eq 0 ] && [ "$actual" = "$expected" ]; then
    printf '  ✓ %s\n' "$name"; PASS=$((PASS+1))
  else
    printf '  ✗ %s: exit=%s decision=%s, expected=%s\n' "$name" "$rc" "$actual" "$expected"
    FAIL=$((FAIL+1))
  fi
}

check "object plan path denied" deny "$(jq -nc '{tool_name:"Edit",tool_input:{file_path:"/tmp/docs/plans/a.md"}}')"
check "object source path allowed" allow "$(jq -nc '{tool_name:"Edit",tool_input:{file_path:"/tmp/source.txt"}}')"
patch=$'*** Begin Patch\n*** Update File: /tmp/source.txt\n@@\n+x\n*** Move to: /tmp/docs/plans/a.md\n*** End Patch'
check "multi-file move into plans denied" deny "$(jq -nc --arg p "$patch" '{tool_name:"Edit",tool_input:$p}')"
patch=$'*** Begin Patch\n*** Update File: /tmp/source.txt\n@@\n+x\n*** End Patch'
check "source patch allowed" allow "$(jq -nc --arg p "$patch" '{tool_name:"Edit",tool_input:$p}')"
check "malformed patch denied" deny '{"tool_name":"Edit","tool_input":"not a patch"}'
: > "$TMP_VAULT/_shared/forge-active"
patch=$'*** Begin Patch\n*** Add File: /tmp/docs/plans/a.md\n+x\n*** End Patch'
check "inactive marker preserves allow behavior" allow "$(jq -nc --arg p "$patch" '{tool_name:"Edit",tool_input:$p}')"
printf '── %s passed, %s failed ──\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
