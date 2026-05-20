#!/usr/bin/env bash
# Tests forge-context.sh bootstrap-classify subcommand

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_CONTEXT="$SCRIPT_DIR/../forge-context.sh"

PASS=0; FAIL=0

setup() {
  TMP=$(mktemp -d)
  TMP_CONF="$TMP/forge.conf"
  echo "VAULT_PATH=$TMP" > "$TMP_CONF"
  mkdir -p "$TMP/_shared"
  cat > "$TMP/_shared/friction-log.md" <<'EOF'
# Friction Log

### 2026-05-10 — permission prompt on rg invocation
- Agent ran rg without proper allowlist
- Root cause: missing Bash(rg:*) pattern

### 2026-05-12 — Stop hook fired during entry
- Wellness hook didn't check marker state
- Root cause: marker-state check missing in hook

### 2026-05-14 — header drift again
- Forge mode header not present
- Root cause: nothing injects it; agent forgets

## 2026-05-15 — legacy level-2 entry, permission prompt on jq
- Hand-written historical entry uses ## not ###
- Root cause: missing Bash(jq:*) allowlist
EOF
  export FORGE_CONF_OVERRIDE="$TMP_CONF"
}

teardown() {
  rm -rf "$TMP"
  unset FORGE_CONF_OVERRIDE TMP TMP_CONF
}

echo "Check 1 — produces friction-classified.json"
setup
"$FORGE_CONTEXT" bootstrap-classify > /dev/null 2>&1
rc=$?
[ $rc -eq 0 ] && { echo "  ✓ exit 0"; PASS=$((PASS+1)); } || { echo "  ✗ exit $rc"; FAIL=$((FAIL+1)); }
[ -f "$TMP/_shared/friction-classified.json" ] && { echo "  ✓ classified.json created"; PASS=$((PASS+1)); } || { echo "  ✗ classified.json missing"; FAIL=$((FAIL+1)); }

echo ""
echo "Check 2 — heuristic classification: 'permission prompt on rg' → allowlist-patch"
out=$(jq -r '.entries[] | select(.description | test("permission prompt on rg")) | .pattern' "$TMP/_shared/friction-classified.json")
[ "$out" = "allowlist-patch" ] && { echo "  ✓ classified as allowlist-patch"; PASS=$((PASS+1)); } || { echo "  ✗ wrong classification: $out"; FAIL=$((FAIL+1)); }

echo ""
echo "Check 3 — heuristic classification: 'hook fired' → marker-state-guard"
out=$(jq -r '.entries[] | select(.description | test("Stop hook fired")) | .pattern' "$TMP/_shared/friction-classified.json")
[ "$out" = "marker-state-guard" ] && { echo "  ✓ classified as marker-state-guard"; PASS=$((PASS+1)); } || { echo "  ✗ wrong classification: $out"; FAIL=$((FAIL+1)); }

echo ""
echo "Check 4 — heuristic classification: 'header drift' → hook-injection"
out=$(jq -r '.entries[] | select(.description | test("header drift")) | .pattern' "$TMP/_shared/friction-classified.json")
[ "$out" = "hook-injection" ] && { echo "  ✓ classified as hook-injection"; PASS=$((PASS+1)); } || { echo "  ✗ wrong classification: $out"; FAIL=$((FAIL+1)); }

echo ""
echo "Check 5 — accepts both ## and ### header levels (4 entries total)"
count=$(jq '.entries | length' "$TMP/_shared/friction-classified.json")
[ "$count" = "4" ] && { echo "  ✓ both ## and ### levels parsed (count=4)"; PASS=$((PASS+1)); } || { echo "  ✗ wrong entry count: $count (expected 4)"; FAIL=$((FAIL+1)); }
out=$(jq -r '.entries[] | select(.description | test("legacy level-2")) | .pattern' "$TMP/_shared/friction-classified.json")
[ "$out" = "allowlist-patch" ] && { echo "  ✓ ##-level entry classified correctly"; PASS=$((PASS+1)); } || { echo "  ✗ ##-level entry wrong/missing: $out"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "Check 6 — non-header lines absorbed into body, malformed header NOT parsed as entry"
setup
cat >> "$TMP/_shared/friction-log.md" <<'EOF'

malformed entry no header
### not-a-date — should-not-be-parsed
EOF
"$FORGE_CONTEXT" bootstrap-classify 2>/dev/null
rc=$?
[ $rc -eq 0 ] && { echo "  ✓ exit 0"; PASS=$((PASS+1)); } || { echo "  ✗ exit $rc on malformed input"; FAIL=$((FAIL+1)); }
count=$(jq '.entries | length' "$TMP/_shared/friction-classified.json")
[ "$count" = "4" ] && { echo "  ✓ malformed header skipped (entry count still 4)"; PASS=$((PASS+1)); } || { echo "  ✗ wrong entry count: $count (expected 4)"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "Check 7 — accepts ASCII hyphen separator (historical hand-written entries)"
# Regression: header regex used to require literal em-dash (—) only; hand-written
# entries with plain ASCII hyphen were silently absorbed into the previous entry's body.
setup
cat > "$TMP/_shared/friction-log.md" <<'EOF'
# Friction Log

### 2026-05-10 - permission prompt on rg invocation
- ASCII hyphen separator (hand-written style)

### 2026-05-11 — header injection issue
- Em-dash separator (append-friction style)
EOF
"$FORGE_CONTEXT" bootstrap-classify > /dev/null 2>&1
rc=$?
[ $rc -eq 0 ] && { echo "  ✓ exit 0"; PASS=$((PASS+1)); } || { echo "  ✗ exit $rc"; FAIL=$((FAIL+1)); }
count=$(jq '.entries | length' "$TMP/_shared/friction-classified.json")
[ "$count" = "2" ] && { echo "  ✓ both hyphen and em-dash entries parsed (count=2)"; PASS=$((PASS+1)); } || { echo "  ✗ wrong entry count: $count (expected 2 — hyphen entry skipped?)"; FAIL=$((FAIL+1)); }
out=$(jq -r '.entries[] | select(.description | test("permission prompt on rg")) | .pattern' "$TMP/_shared/friction-classified.json")
[ "$out" = "allowlist-patch" ] && { echo "  ✓ hyphen-separated entry classified"; PASS=$((PASS+1)); } || { echo "  ✗ hyphen entry missing/wrong: $out"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "── Total: $PASS pass, $FAIL fail ──"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
