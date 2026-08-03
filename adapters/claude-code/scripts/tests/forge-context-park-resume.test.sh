#!/usr/bin/env bash
# Test runner for forge-context.sh park / resume (excursion parking).
# Pure bash, no framework. Pattern follows forge-context-substrate-check.test.sh.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../forge-context.sh"
PASS=0; FAIL=0
assert_contains() { local n="$1" needle="$2" hay="$3"
  if echo "$hay" | grep -qF "$needle"; then echo "  ✓ $n"; PASS=$((PASS+1))
  else echo "  ✗ $n — missing: $needle"; echo "    Got: $hay"; FAIL=$((FAIL+1)); fi; }
assert_eq() { local n="$1" exp="$2" act="$3"
  if [ "$exp" = "$act" ]; then echo "  ✓ $n"; PASS=$((PASS+1))
  else echo "  ✗ $n — expected [$exp] got [$act]"; FAIL=$((FAIL+1)); fi; }

mk_vault() {
  local v; v=$(mktemp -d)
  mkdir -p "$v/_shared" "$v/PERSO/forge" "$v/PERSO/SimpleHIIT"
  printf -- '---\ndate: 2026-08-03\nproject: forge\nsession: open\n---\n' > "$v/PERSO/forge/current-checkpoint.md"
  printf -- '---\ndate: 2026-08-01\nproject: SimpleHIIT\nsession: closed\n---\n' > "$v/PERSO/SimpleHIIT/current-checkpoint.md"
  echo "$v"
}
mk_conf() { local v="$1" c; c=$(mktemp)
  cat >"$c" <<EOF
VAULT_PATH=$v
FORGE_REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
EOF
  echo "$c"; }
write_active() { printf '{"session_id":"sess-1","project":"%s","started_at":"2026-08-03T07:52:00+0200","tmux_pane":"%%3"}' "$2" > "$1/_shared/forge-active"; }

echo "=== park ==="
V=$(mk_vault); C=$(mk_conf "$V"); write_active "$V" forge
FORGE_CONF_OVERRIDE="$C" CLAUDE_CODE_SESSION_ID=sess-1 "$SCRIPT" park SimpleHIIT "waiting on CI" >/dev/null 2>&1
M=$(cat "$V/_shared/forge-active")
assert_eq "project re-points to target" "SimpleHIIT" "$(echo "$M" | jq -r '.project')"
assert_eq "started_at preserved (no reset)" "2026-08-03T07:52:00+0200" "$(echo "$M" | jq -r '.started_at')"
assert_eq "session_id preserved" "sess-1" "$(echo "$M" | jq -r '.session_id')"
assert_eq "parked.project = former active" "forge" "$(echo "$M" | jq -r '.parked.project')"
assert_eq "parked.reason stored" "waiting on CI" "$(echo "$M" | jq -r '.parked.reason')"
assert_eq "parked.env resolved" "PERSO" "$(echo "$M" | jq -r '.parked.env')"

# already-parked → error, marker unchanged
before=$(cat "$V/_shared/forge-active")
out=$(FORGE_CONF_OVERRIDE="$C" CLAUDE_CODE_SESSION_ID=sess-1 "$SCRIPT" park forge "waiting again" 2>&1); rc=$?
assert_eq "park-while-parked exits 2" "2" "$rc"
assert_contains "park-while-parked explains" "already parked" "$out"
assert_eq "marker untouched on refusal" "$before" "$(cat "$V/_shared/forge-active")"

# unknown target → error
V2=$(mk_vault); C2=$(mk_conf "$V2"); write_active "$V2" forge
out=$(FORGE_CONF_OVERRIDE="$C2" CLAUDE_CODE_SESSION_ID=sess-1 "$SCRIPT" park ghost "x" 2>&1); rc=$?
assert_eq "unknown target exits 2" "2" "$rc"
assert_contains "unknown target explained" "unknown" "$out"

echo; echo "Pass: $PASS  Fail: $FAIL"; [ "$FAIL" -eq 0 ]
