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
FORGE_CONF_OVERRIDE="$C" COPILOT_SESSION_ID=sess-1 "$SCRIPT" park SimpleHIIT "waiting on CI" >/dev/null 2>&1
M=$(cat "$V/_shared/forge-active")
assert_eq "project re-points to target" "SimpleHIIT" "$(echo "$M" | jq -r '.project')"
assert_eq "started_at preserved (no reset)" "2026-08-03T07:52:00+0200" "$(echo "$M" | jq -r '.started_at')"
assert_eq "session_id preserved" "sess-1" "$(echo "$M" | jq -r '.session_id')"
assert_eq "parked.project = former active" "forge" "$(echo "$M" | jq -r '.parked.project')"
assert_eq "parked.reason stored" "waiting on CI" "$(echo "$M" | jq -r '.parked.reason')"
assert_eq "parked.env resolved" "PERSO" "$(echo "$M" | jq -r '.parked.env')"
# marker must stay compact single-line (canonical writer uses printf, not pretty jq)
nl=$(wc -l < "$V/_shared/forge-active" | tr -d ' ')
if [ "$nl" -le 1 ]; then echo "  ✓ park marker is compact (≤1 newline, got $nl)"; PASS=$((PASS+1))
else echo "  ✗ park marker is compact — expected ≤1 newline, got $nl (pretty multi-line)"; FAIL=$((FAIL+1)); fi
# park must flip the TARGET project's checkpoint session closed→open (via flip_session_to_open);
# SimpleHIIT was set up with session: closed, so open here proves the flip fired.
tgt_sess=$(grep -m1 '^session:' "$V/PERSO/SimpleHIIT/current-checkpoint.md" | sed 's/^session:[[:space:]]*//')
assert_eq "park flips target checkpoint session to open" "open" "$tgt_sess"

# already-parked → error, marker unchanged
before=$(cat "$V/_shared/forge-active")
out=$(FORGE_CONF_OVERRIDE="$C" COPILOT_SESSION_ID=sess-1 "$SCRIPT" park forge "waiting again" 2>&1); rc=$?
assert_eq "park-while-parked exits 2" "2" "$rc"
assert_contains "park-while-parked explains" "already parked" "$out"
assert_eq "marker untouched on refusal" "$before" "$(cat "$V/_shared/forge-active")"

# unknown target → error
V2=$(mk_vault); C2=$(mk_conf "$V2"); write_active "$V2" forge
out=$(FORGE_CONF_OVERRIDE="$C2" COPILOT_SESSION_ID=sess-1 "$SCRIPT" park ghost "x" 2>&1); rc=$?
assert_eq "unknown target exits 2" "2" "$rc"
assert_contains "unknown target explained" "unknown" "$out"

echo "=== resume ==="
V3=$(mk_vault); C3=$(mk_conf "$V3"); write_active "$V3" forge
FORGE_CONF_OVERRIDE="$C3" COPILOT_SESSION_ID=sess-1 "$SCRIPT" park SimpleHIIT "waiting on CI" >/dev/null 2>&1
FORGE_CONF_OVERRIDE="$C3" COPILOT_SESSION_ID=sess-1 "$SCRIPT" resume >/dev/null 2>&1
M3=$(cat "$V3/_shared/forge-active")
assert_eq "resume restores parked project" "forge" "$(echo "$M3" | jq -r '.project')"
assert_eq "resume drops parked slot" "null" "$(echo "$M3" | jq -r '.parked // "null"')"
assert_eq "resume preserves started_at" "2026-08-03T07:52:00+0200" "$(echo "$M3" | jq -r '.started_at')"
assert_eq "resume preserves session_id" "sess-1" "$(echo "$M3" | jq -r '.session_id')"

# nothing parked → error
V4=$(mk_vault); C4=$(mk_conf "$V4"); write_active "$V4" forge
out=$(FORGE_CONF_OVERRIDE="$C4" COPILOT_SESSION_ID=sess-1 "$SCRIPT" resume 2>&1); rc=$?
assert_eq "resume-with-nothing-parked exits 2" "2" "$rc"
assert_contains "resume explains nothing parked" "nothing parked" "$out"

echo "=== status parked chip ==="
V5=$(mk_vault); C5=$(mk_conf "$V5"); write_active "$V5" forge
FORGE_CONF_OVERRIDE="$C5" COPILOT_SESSION_ID=sess-1 "$SCRIPT" park SimpleHIIT "waiting on CI" >/dev/null 2>&1
out=$(FORGE_CONF_OVERRIDE="$C5" COPILOT_SESSION_ID=sess-1 "$SCRIPT" status 2>/dev/null)
assert_contains "status shows active target" "SimpleHIIT" "$out"
assert_contains "status shows parked chip" "⏸ forge" "$out"

echo "=== round-trip byte identity ==="
# A park→resume cycle must leave the marker byte-identical to the original compact
# marker (values AND format). Guards against the marker silently flipping from
# compact single-line to pretty multi-line on first park.
V6=$(mk_vault); C6=$(mk_conf "$V6"); write_active "$V6" forge
SNAP=$(mktemp); cp "$V6/_shared/forge-active" "$SNAP"
FORGE_CONF_OVERRIDE="$C6" COPILOT_SESSION_ID=sess-1 "$SCRIPT" park SimpleHIIT "waiting on CI" >/dev/null 2>&1
FORGE_CONF_OVERRIDE="$C6" COPILOT_SESSION_ID=sess-1 "$SCRIPT" resume >/dev/null 2>&1
if diff "$SNAP" "$V6/_shared/forge-active" >/dev/null 2>&1; then
  echo "  ✓ park→resume marker is byte-identical to original compact marker"; PASS=$((PASS+1))
else
  echo "  ✗ park→resume marker differs from original (raw diff):"; diff "$SNAP" "$V6/_shared/forge-active" | sed 's/^/    /'; FAIL=$((FAIL+1))
fi

echo; echo "Pass: $PASS  Fail: $FAIL"; [ "$FAIL" -eq 0 ]
