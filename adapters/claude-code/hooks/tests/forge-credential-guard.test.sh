#!/usr/bin/env bash
# Test runner for forge-credential-guard.sh PreToolUse hook.
#
# Strategy: pipe a PreToolUse-shaped JSON payload to the hook and assert the
# ask/allow decision. The hook is always-on (no marker/env setup needed).
#
# ASK cases   : inspection verb + credential-bearing file
# ALLOW cases : non-credential file, non-inspection verb, non-Bash tool,
#               recommended tool-validation alternatives

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_FILE="$SCRIPT_DIR/../forge-credential-guard.sh"

PASS=0
FAIL=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ✓ $name"; PASS=$((PASS+1))
  else
    echo "  ✗ $name — expected '$expected', got '$actual'"; FAIL=$((FAIL+1))
  fi
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF -e "$needle"; then
    echo "  ✓ $name"; PASS=$((PASS+1))
  else
    echo "  ✗ $name — did not find '$needle' in output"; FAIL=$((FAIL+1))
  fi
}

# Invoke hook with a Bash command string → return stdout.
invoke_cmd() {
  local cmd="$1"
  jq -n --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}' | bash "$HOOK_FILE" 2>/dev/null
}

echo "=== forge-credential-guard ==="

# ---- ASK cases: inspection verb + credential file ----
assert_contains "gradle.properties greedy grep → ask" '"permissionDecision": "ask"' \
  "$(invoke_cmd "grep -i artifactory ~/.gradle/gradle.properties")"
assert_contains "ask reason names the file" 'gradle.properties' \
  "$(invoke_cmd "grep -i artifactory ~/.gradle/gradle.properties")"
assert_contains "cat gradle.properties → ask" '"permissionDecision": "ask"' \
  "$(invoke_cmd "cat ~/.gradle/gradle.properties")"
assert_contains "cat .netrc → ask" '"permissionDecision": "ask"' \
  "$(invoke_cmd "cat ~/.netrc")"
assert_contains "cat .aws/credentials → ask" '"permissionDecision": "ask"' \
  "$(invoke_cmd "cat ~/.aws/credentials")"
assert_contains "head .env → ask" '"permissionDecision": "ask"' \
  "$(invoke_cmd "head -5 .env")"
assert_contains "head .env.local → ask" '"permissionDecision": "ask"' \
  "$(invoke_cmd "head .env.local")"
assert_contains "cat ssh private key → ask" '"permissionDecision": "ask"' \
  "$(invoke_cmd "cat ~/.ssh/id_ed25519")"
assert_contains "cat *.pem → ask" '"permissionDecision": "ask"' \
  "$(invoke_cmd "cat ./certs/private.pem")"
assert_contains "cat secrets.json → ask" '"permissionDecision": "ask"' \
  "$(invoke_cmd "cat config/secrets.json")"
assert_contains "sudo cat npmrc → ask" '"permissionDecision": "ask"' \
  "$(invoke_cmd "sudo cat ~/.npmrc")"
assert_contains "credential file mid-pipeline → ask" '"permissionDecision": "ask"' \
  "$(invoke_cmd "cat ~/.git-credentials | grep github")"
# key-only grep on a credential file still asks (hook doesn't distinguish; the
# prompt confirms intent, prose rule guides toward the safe pattern)
assert_contains "key-only grep on credential file still asks" '"permissionDecision": "ask"' \
  "$(invoke_cmd "grep -oE '^[A-Z_]+' ~/.gradle/gradle.properties")"

# ---- ALLOW cases ----
assert_eq "grep token in source → allow" "" \
  "$(invoke_cmd "grep -rn token src/")"
assert_eq "grep secret-ish word in source → allow" "" \
  "$(invoke_cmd "grep -n secretSauce src/main.kt")"
assert_eq "cat normal file → allow" "" \
  "$(invoke_cmd "cat README.md")"
assert_eq "ls credential dir (no content print) → allow" "" \
  "$(invoke_cmd "ls -la ~/.ssh/")"
assert_eq "gradlew tasks (recommended alternative) → allow" "" \
  "$(invoke_cmd "./gradlew tasks")"
assert_eq "gh auth status (recommended alternative) → allow" "" \
  "$(invoke_cmd "gh auth status")"
assert_eq "wildcat substring not matched as cat → allow" "" \
  "$(invoke_cmd "wildcat --version")"
assert_eq "non-Bash tool (Edit) → allow" "" \
  "$(jq -n '{tool_name:"Edit", tool_input:{file_path:"/x/.env"}}' | bash "$HOOK_FILE" 2>/dev/null)"
assert_eq "empty command → allow" "" \
  "$(invoke_cmd "")"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
