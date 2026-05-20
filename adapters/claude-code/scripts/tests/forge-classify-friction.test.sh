#!/usr/bin/env bash
# Test runner for forge-classify-friction.sh

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLASSIFIER="$SCRIPT_DIR/../forge-classify-friction.sh"

PASS=0; FAIL=0

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ✓ $name"
    PASS=$((PASS+1))
  else
    echo "  ✗ $name — expected '$expected', got '$actual'"
    FAIL=$((FAIL+1))
  fi
}

echo "Check 1 — JSON input: permission prompt + safe + glob subtlety → allowlist-patch"
out=$("$CLASSIFIER" --json-input - <<'EOF'
{"q1_perm_prompt": true, "q2_safe_to_allowlist": true, "q3_glob_subtlety": true}
EOF
)
assert_eq "returns allowlist-patch" "allowlist-patch" "$(echo "$out" | jq -r '.pattern')"

echo ""
echo "Check 2 — JSON input: permission prompt + safe + no glob + wrap_safer → wrapper-subcommand"
out=$("$CLASSIFIER" --json-input - <<'EOF'
{"q1_perm_prompt": true, "q2_safe_to_allowlist": true, "q3_glob_subtlety": false, "q4_wrap_safer": true}
EOF
)
assert_eq "returns wrapper-subcommand" "wrapper-subcommand" "$(echo "$out" | jq -r '.pattern')"

echo ""
echo "Check 3 — JSON input: hook fired wrong → marker-state-guard"
out=$("$CLASSIFIER" --json-input - <<'EOF'
{"q1_perm_prompt": false, "q5_hook_misfire": true}
EOF
)
assert_eq "returns marker-state-guard" "marker-state-guard" "$(echo "$out" | jq -r '.pattern')"

echo ""
echo "Check 4 — JSON input: prose drift + verbatim → hook-injection"
out=$("$CLASSIFIER" --json-input - <<'EOF'
{"q1_perm_prompt": false, "q5_hook_misfire": false, "q6_prose_drift": true, "q7_verbatim": true}
EOF
)
assert_eq "returns hook-injection" "hook-injection" "$(echo "$out" | jq -r '.pattern')"

echo ""
echo "Check 5 — JSON input: structured text drift → template-slot"
out=$("$CLASSIFIER" --json-input - <<'EOF'
{"q1_perm_prompt": false, "q5_hook_misfire": false, "q6_prose_drift": false, "q8_structured_drift": true}
EOF
)
assert_eq "returns template-slot" "template-slot" "$(echo "$out" | jq -r '.pattern')"

echo ""
echo "Check 6 — JSON input: unsafe permission op → needs_new_pattern"
out=$("$CLASSIFIER" --json-input - <<'EOF'
{"q1_perm_prompt": true, "q2_safe_to_allowlist": false}
EOF
)
assert_eq "returns needs_new_pattern" "needs_new_pattern" "$(echo "$out" | jq -r '.pattern')"

echo ""
echo "Check 7 — JSON input: stylistic (not verbatim) prose drift → needs_new_pattern"
out=$("$CLASSIFIER" --json-input - <<'EOF'
{"q1_perm_prompt": false, "q5_hook_misfire": false, "q6_prose_drift": true, "q7_verbatim": false}
EOF
)
assert_eq "returns needs_new_pattern" "needs_new_pattern" "$(echo "$out" | jq -r '.pattern')"

echo ""
echo "Check 8 — Description echoed in output"
out=$("$CLASSIFIER" --json-input - --description "test event" <<'EOF'
{"q1_perm_prompt": true, "q2_safe_to_allowlist": false}
EOF
)
assert_eq "description preserved" "test event" "$(echo "$out" | jq -r '.description')"

echo ""
echo "── Total: $PASS pass, $FAIL fail ──"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
