#!/usr/bin/env bash
# Tests forge-context.sh append-friction subcommand

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_CONTEXT="$SCRIPT_DIR/../forge-context.sh"

PASS=0; FAIL=0

setup_tmp_vault() {
  TMP=$(mktemp -d)
  mkdir -p "$TMP/_shared/tasks/open"
  : > "$TMP/_shared/friction-log.md"
  echo '{"entries":[]}' > "$TMP/_shared/friction-classified.json"
  # Mock forge.conf
  TMP_CONF="$TMP/forge.conf"
  echo "VAULT_PATH=$TMP" > "$TMP_CONF"
  # Mock catalog (minimum entry for validation)
  mkdir -p "$TMP/_mock_catalog"
  cat > "$TMP/_mock_catalog/script-replacement-patterns.md" <<'EOF'
# patterns

## allowlist-patch
**When to use:** test
**How it works:** test
**Exemplar:** test
**Anti-pattern:** test
**Scaffold:** test

## hook-injection
**When to use:** test
**How it works:** test
**Exemplar:** test
**Anti-pattern:** test
**Scaffold:** test
EOF
  export FORGE_CONF_OVERRIDE="$TMP_CONF"
  export FORGE_PATTERN_CATALOG="$TMP/_mock_catalog/script-replacement-patterns.md"
}

teardown() {
  rm -rf "$TMP"
  unset FORGE_CONF_OVERRIDE FORGE_PATTERN_CATALOG TMP TMP_CONF
}

assert_exit() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then echo "  ✓ $name"; PASS=$((PASS+1));
  else echo "  ✗ $name — expected exit $expected, got $actual"; FAIL=$((FAIL+1)); fi
}

assert_file_contains() {
  local name="$1"; local file="$2"; local needle="$3"
  if grep -qF "$needle" "$file" 2>/dev/null; then echo "  ✓ $name"; PASS=$((PASS+1));
  else echo "  ✗ $name — $file did not contain: $needle"; FAIL=$((FAIL+1)); fi
}

assert_file_not_contains() {
  local name="$1"; local file="$2"; local needle="$3"
  if ! grep -qF "$needle" "$file" 2>/dev/null; then echo "  ✓ $name"; PASS=$((PASS+1));
  else echo "  ✗ $name — $file unexpectedly contained: $needle"; FAIL=$((FAIL+1)); fi
}

echo "Check 1 — happy path: valid pattern, recurrence=1, auto-create stub"
setup_tmp_vault
"$FORGE_CONTEXT" append-friction \
  --date 2026-05-20 \
  --description "test event A" \
  --pattern allowlist-patch \
  --recurrence 1 \
  --action-ref "tasks/open/2026-05-20-test-a.md" >/dev/null 2>&1
rc=$?
assert_exit "exit 0" "0" "$rc"
assert_file_contains "friction-log entry written" "$TMP/_shared/friction-log.md" "test event A"
assert_file_contains "friction-log entry has pattern" "$TMP/_shared/friction-log.md" "allowlist-patch"
assert_file_contains "classified JSON updated" "$TMP/_shared/friction-classified.json" "test event A"
[ -f "$TMP/_shared/tasks/open/2026-05-20-test-a.md" ] && { echo "  ✓ stub task auto-created (recurrence=1)"; PASS=$((PASS+1)); } || { echo "  ✗ stub task NOT created"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "Check 2 — recurrence > 1: no stub creation"
setup_tmp_vault
mkdir -p "$TMP/_shared/tasks/open"
echo "pre-existing" > "$TMP/_shared/tasks/open/2026-05-20-test-b.md"
"$FORGE_CONTEXT" append-friction \
  --date 2026-05-20 \
  --description "test event B recurrence" \
  --pattern hook-injection \
  --recurrence 2 \
  --action-ref "tasks/open/2026-05-20-test-b.md" >/dev/null 2>&1
rc=$?
assert_exit "exit 0" "0" "$rc"
assert_file_contains "friction-log appended" "$TMP/_shared/friction-log.md" "test event B recurrence"
# Existing task unchanged
content=$(cat "$TMP/_shared/tasks/open/2026-05-20-test-b.md")
[ "$content" = "pre-existing" ] && { echo "  ✓ existing task untouched"; PASS=$((PASS+1)); } || { echo "  ✗ existing task overwritten"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "Check 3 — invalid pattern: write-then-flag (non-zero exit, fallback entry written, validation_failed flag)"
setup_tmp_vault
"$FORGE_CONTEXT" append-friction \
  --date 2026-05-20 \
  --description "test event C bad pattern" \
  --pattern bogus-pattern \
  --recurrence 1 \
  --action-ref "tasks/open/2026-05-20-test-c.md" >/dev/null 2>&1
rc=$?
[ $rc -ne 0 ] && { echo "  ✓ exit non-zero on invalid pattern"; PASS=$((PASS+1)); } || { echo "  ✗ exit was 0, expected non-zero"; FAIL=$((FAIL+1)); }
assert_file_contains "fallback entry still written to friction-log" "$TMP/_shared/friction-log.md" "test event C bad pattern"
assert_file_contains "fallback entry tagged validation_failed" "$TMP/_shared/friction-classified.json" "validation_failed"
assert_file_contains "original failed pattern preserved" "$TMP/_shared/friction-classified.json" "bogus-pattern"
assert_file_contains "fallback pattern is unknown" "$TMP/_shared/friction-classified.json" "\"pattern\":\"unknown\""
teardown

echo ""
echo "Check 4 — needs_new_pattern: accepted as valid escape value"
setup_tmp_vault
"$FORGE_CONTEXT" append-friction \
  --date 2026-05-20 \
  --description "test event D no pattern" \
  --pattern needs_new_pattern \
  --recurrence 1 \
  --action-ref needs_new_pattern >/dev/null 2>&1
rc=$?
assert_exit "exit 0" "0" "$rc"
assert_file_contains "needs_new_pattern entry written" "$TMP/_shared/friction-log.md" "needs_new_pattern"
teardown

echo ""
echo "Check 5 — active marker with resolvable ENV: stub auto-prefixed with {ENV}/{project}/"
setup_tmp_vault
# Create the project subtree so extract_marker_env can resolve it
mkdir -p "$TMP/PERSO/forge"
# Write a JSON marker pointing to PERSO/forge
cat > "$TMP/_shared/forge-active" <<'EOF'
{"session_id":"test-session","project":"forge","started_at":"2026-05-20T10:00:00+0200","tmux_pane":null}
EOF
"$FORGE_CONTEXT" append-friction \
  --date 2026-05-20 \
  --description "marker-driven prefix" \
  --pattern allowlist-patch \
  --recurrence 1 \
  --action-ref "tasks/open/2026-05-20-marker-test.md" >/dev/null 2>&1
rc=$?
assert_exit "exit 0" "0" "$rc"
[ -f "$TMP/PERSO/forge/tasks/open/2026-05-20-marker-test.md" ] && { echo "  ✓ stub created under PERSO/forge/"; PASS=$((PASS+1)); } || { echo "  ✗ stub not at PERSO/forge/tasks/open/"; FAIL=$((FAIL+1)); }
[ ! -f "$TMP/_shared/tasks/open/2026-05-20-marker-test.md" ] && { echo "  ✓ stub NOT created under _shared/ (correctly skipped)"; PASS=$((PASS+1)); } || { echo "  ✗ stub leaked to _shared/"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "Check 6 — no marker: stub falls back to _shared/ (existing behavior preserved)"
setup_tmp_vault
# Marker missing — no extract_marker_project hit
"$FORGE_CONTEXT" append-friction \
  --date 2026-05-20 \
  --description "no-marker fallback" \
  --pattern allowlist-patch \
  --recurrence 1 \
  --action-ref "tasks/open/2026-05-20-nomarker-test.md" >/dev/null 2>&1
rc=$?
assert_exit "exit 0" "0" "$rc"
[ -f "$TMP/_shared/tasks/open/2026-05-20-nomarker-test.md" ] && { echo "  ✓ stub fell back to _shared/"; PASS=$((PASS+1)); } || { echo "  ✗ fallback failed"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "Check 7 — marker active but project subtree missing: falls back to _shared/"
setup_tmp_vault
# Marker set but no $TMP/*/forge directory exists → extract_marker_env returns empty
cat > "$TMP/_shared/forge-active" <<'EOF'
{"session_id":"test-session","project":"ghost-project","started_at":"2026-05-20T10:00:00+0200","tmux_pane":null}
EOF
"$FORGE_CONTEXT" append-friction \
  --date 2026-05-20 \
  --description "unresolvable project" \
  --pattern allowlist-patch \
  --recurrence 1 \
  --action-ref "tasks/open/2026-05-20-ghost-test.md" >/dev/null 2>&1
rc=$?
assert_exit "exit 0" "0" "$rc"
[ -f "$TMP/_shared/tasks/open/2026-05-20-ghost-test.md" ] && { echo "  ✓ fell back to _shared/ when ENV unresolvable"; PASS=$((PASS+1)); } || { echo "  ✗ fallback failed"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "Check 8 — action-ref already absolute (starts with ENV/): not re-prefixed"
setup_tmp_vault
mkdir -p "$TMP/PERSO/forge"
cat > "$TMP/_shared/forge-active" <<'EOF'
{"session_id":"test-session","project":"forge","started_at":"2026-05-20T10:00:00+0200","tmux_pane":null}
EOF
"$FORGE_CONTEXT" append-friction \
  --date 2026-05-20 \
  --description "absolute action-ref" \
  --pattern allowlist-patch \
  --recurrence 1 \
  --action-ref "PERSO/forge/tasks/open/2026-05-20-absolute-test.md" >/dev/null 2>&1
rc=$?
assert_exit "exit 0" "0" "$rc"
[ -f "$TMP/PERSO/forge/tasks/open/2026-05-20-absolute-test.md" ] && { echo "  ✓ absolute path respected"; PASS=$((PASS+1)); } || { echo "  ✗ absolute path mishandled"; FAIL=$((FAIL+1)); }
[ ! -f "$TMP/PERSO/forge/PERSO/forge/tasks/open/2026-05-20-absolute-test.md" ] && { echo "  ✓ no double-prefix"; PASS=$((PASS+1)); } || { echo "  ✗ double-prefix detected"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "Check 9 — non-numeric --recurrence: clean error, no jq leak, no file mutation"
setup_tmp_vault
err=$("$FORGE_CONTEXT" append-friction \
  --date 2026-05-20 \
  --description "test event I non-numeric recurrence" \
  --pattern allowlist-patch \
  --recurrence "first-observed" \
  --action-ref "tasks/open/2026-05-20-test-i.md" 2>&1 >/dev/null)
rc=$?
assert_exit "exit 2 on non-numeric recurrence" "2" "$rc"
if printf '%s' "$err" | grep -q "must be a non-negative integer"; then
  echo "  ✓ error message names the constraint"; PASS=$((PASS+1));
else
  echo "  ✗ error message missing constraint name (got: $err)"; FAIL=$((FAIL+1));
fi
if printf '%s' "$err" | grep -qi "argjson\|invalid JSON"; then
  echo "  ✗ raw jq error leaked through"; FAIL=$((FAIL+1));
else
  echo "  ✓ no raw jq error leak"; PASS=$((PASS+1));
fi
assert_file_not_contains "no friction-log mutation on rejection" "$TMP/_shared/friction-log.md" "test event I"
assert_file_not_contains "no JSON mutation on rejection" "$TMP/_shared/friction-classified.json" "test event I"
teardown

echo ""
echo "Check 10 — non-path --action-ref 'none': clean error, no mutation, no garbage file"
setup_tmp_vault
err=$("$FORGE_CONTEXT" append-friction \
  --date 2026-05-20 \
  --description "test event J none action-ref" \
  --pattern allowlist-patch \
  --recurrence 1 \
  --action-ref "none" 2>&1 >/dev/null)
rc=$?
assert_exit "exit 2 on non-path action-ref" "2" "$rc"
if printf '%s' "$err" | grep -qF "needs_new_pattern"; then
  echo "  ✓ error message names the escape value"; PASS=$((PASS+1));
else
  echo "  ✗ error message missing 'needs_new_pattern' (got: $err)"; FAIL=$((FAIL+1));
fi
assert_file_not_contains "no friction-log mutation on rejection" "$TMP/_shared/friction-log.md" "test event J"
assert_file_not_contains "no JSON mutation on rejection" "$TMP/_shared/friction-classified.json" "test event J"
[ ! -f "$TMP/none" ] && { echo "  ✓ no garbage file at vault root"; PASS=$((PASS+1)); } || { echo "  ✗ garbage file 'none' written at vault root"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "Check 11 — prose --action-ref (the 2026-06-08 case): rejected, no garbage file"
setup_tmp_vault
"$FORGE_CONTEXT" append-friction \
  --date 2026-05-20 \
  --description "test event K prose action-ref" \
  --pattern allowlist-patch \
  --recurrence 1 \
  --action-ref "commit: TBD this session" >/dev/null 2>&1
rc=$?
assert_exit "exit 2 on prose action-ref" "2" "$rc"
[ ! -f "$TMP/commit: TBD this session" ] && { echo "  ✓ no garbage file from prose action-ref"; PASS=$((PASS+1)); } || { echo "  ✗ garbage file written from prose"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "Check 12 — env-prefixed task path still accepted (regression guard for Check 8 shape)"
setup_tmp_vault
mkdir -p "$TMP/PERSO/forge"
cat > "$TMP/_shared/forge-active" <<'EOF'
{"session_id":"test-session","project":"forge","started_at":"2026-05-20T10:00:00+0200","tmux_pane":null}
EOF
"$FORGE_CONTEXT" append-friction \
  --date 2026-05-20 \
  --description "env-prefixed accepted" \
  --pattern allowlist-patch \
  --recurrence 1 \
  --action-ref "PERSO/forge/tasks/open/2026-05-20-envpfx.md" >/dev/null 2>&1
rc=$?
assert_exit "exit 0 on env-prefixed task path" "0" "$rc"
[ -f "$TMP/PERSO/forge/tasks/open/2026-05-20-envpfx.md" ] && { echo "  ✓ stub created at env-prefixed path"; PASS=$((PASS+1)); } || { echo "  ✗ stub not created"; FAIL=$((FAIL+1)); }
teardown

echo ""
echo "── Total: $PASS pass, $FAIL fail ──"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
