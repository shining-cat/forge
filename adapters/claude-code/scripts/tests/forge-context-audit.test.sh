#!/usr/bin/env bash
# Tests forge-context.sh audit-prose-rules subcommand

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_CONTEXT="$SCRIPT_DIR/../forge-context.sh"

PASS=0; FAIL=0

setup() {
  TMP=$(mktemp -d)
  TMP_CONF="$TMP/forge.conf"
  echo "VAULT_PATH=$TMP" > "$TMP_CONF"
  mkdir -p "$TMP/_shared" "$TMP/_scan/core" "$TMP/_cache"
  # Planted prose patterns that the audit should detect
  cat > "$TMP/_scan/core/rule1.md" <<'EOF'
# Some rule
You MUST always use the wrapper script.
Never use raw heredocs.
EOF
  cat > "$TMP/_scan/core/rule2.md" <<'EOF'
# Another rule
Remember to update the checkpoint before exit.
EOF
  # Friction-log with recurrence to flag the rule
  cat > "$TMP/_shared/friction-log.md" <<'EOF'
### 2026-05-19 — wrapper not used
- agent used heredoc instead of wrapper

### 2026-05-19 — wrapper not used again
- agent used heredoc instead of wrapper
EOF
  export FORGE_CONF_OVERRIDE="$TMP_CONF"
  export FORGE_AUDIT_SCAN_ROOT="$TMP/_scan"
  export FORGE_AUDIT_CACHE="$TMP/_cache/audit-fingerprints.json"
}

teardown() {
  rm -rf "$TMP"
  unset FORGE_CONF_OVERRIDE FORGE_AUDIT_SCAN_ROOT FORGE_AUDIT_CACHE TMP TMP_CONF
}

echo "Check 1 — detects MUST/Never/Remember prose patterns"
setup
out=$("$FORGE_CONTEXT" audit-prose-rules 2>&1)
echo "$out" | grep -qE 'MUST.*rule1\.md' && { echo "  ✓ flags MUST in rule1"; PASS=$((PASS+1)); } || { echo "  ✗ missed MUST in rule1"; FAIL=$((FAIL+1)); }
echo "$out" | grep -qE 'Never.*rule1\.md' && { echo "  ✓ flags Never in rule1"; PASS=$((PASS+1)); } || { echo "  ✗ missed Never in rule1"; FAIL=$((FAIL+1)); }
echo "$out" | grep -qE 'Remember.*rule2\.md' && { echo "  ✓ flags Remember in rule2"; PASS=$((PASS+1)); } || { echo "  ✗ missed Remember in rule2"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "Check 2 — fingerprint cache: second run reports no new findings"
setup
"$FORGE_CONTEXT" audit-prose-rules > /dev/null 2>&1
out=$("$FORGE_CONTEXT" audit-prose-rules 2>&1)
echo "$out" | grep -qE 'no new findings|0 new' && { echo "  ✓ second run reports nothing new"; PASS=$((PASS+1)); } || { echo "  ✗ second run still reported findings (cache broken)"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "Check 3 — --json output"
setup
out=$("$FORGE_CONTEXT" audit-prose-rules --json 2>&1)
echo "$out" | jq -e '.findings | length > 0' > /dev/null 2>&1 && { echo "  ✓ JSON output parses with non-empty findings"; PASS=$((PASS+1)); } || { echo "  ✗ JSON output invalid or empty"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "── Total: $PASS pass, $FAIL fail ──"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
