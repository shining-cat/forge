#!/usr/bin/env bash
# reconcile_marker must compare the marker against the ACTIVE project's OWN
# checkpoint, not the globally newest checkpoint by mtime. Regression guard for
# the excursion false-positive (marker=B, A's checkpoint newest → spurious nag).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../forge-context.sh"
PASS=0; FAIL=0
assert_absent() { local n="$1" needle="$2" hay="$3"
  if echo "$hay" | grep -qF "$needle"; then echo "  ✗ $n — unexpectedly contained: $needle"; echo "    Got: $hay"; FAIL=$((FAIL+1))
  else echo "  ✓ $n"; PASS=$((PASS+1)); fi; }
assert_contains() { local n="$1" needle="$2" hay="$3"
  if echo "$hay" | grep -qF "$needle"; then echo "  ✓ $n"; PASS=$((PASS+1))
  else echo "  ✗ $n — missing: $needle"; echo "    Got: $hay"; FAIL=$((FAIL+1)); fi; }
assert_eq() { local n="$1" exp="$2" act="$3"
  if [ "$exp" = "$act" ]; then echo "  ✓ $n"; PASS=$((PASS+1))
  else echo "  ✗ $n — expected [$exp] got [$act]"; FAIL=$((FAIL+1)); fi; }

mk() { local v; v=$(mktemp -d); mkdir -p "$v/_shared" "$v/PERSO/forge" "$v/PERSO/SimpleHIIT"; echo "$v"; }
conf() { local v="$1" c; c=$(mktemp); printf 'VAULT_PATH=%s\nFORGE_REPO=%s\n' "$v" "$(cd "$SCRIPT_DIR/../../../.." && pwd)" > "$c"; echo "$c"; }

echo "=== reconcile-marker ==="

# Excursion shape: marker=SimpleHIIT (active), forge's checkpoint is NEWER by mtime
# but that is irrelevant — SimpleHIIT's own checkpoint agrees → NO warning.
V=$(mk); C=$(conf "$V")
printf '{"session_id":"s","project":"SimpleHIIT","started_at":"2026-08-03T07:52:00+0200","tmux_pane":null,"parked":{"project":"forge","env":"PERSO","reason":"CI","parked_at":"x"}}' > "$V/_shared/forge-active"
printf -- '---\ndate: 2026-08-03\nproject: SimpleHIIT\n---\n' > "$V/PERSO/SimpleHIIT/current-checkpoint.md"
sleep 1
printf -- '---\ndate: 2026-08-03\nproject: forge\n---\n' > "$V/PERSO/forge/current-checkpoint.md"  # NEWER mtime
out=$(FORGE_CONF_OVERRIDE="$C" "$SCRIPT" reconcile-marker 2>&1)
assert_absent "no false mismatch during excursion" "Marker mismatch" "$out"

# Genuine corruption: active project's OWN checkpoint names a different project → warn.
V2=$(mk); C2=$(conf "$V2")
printf '{"session_id":"s","project":"forge","started_at":"x","tmux_pane":null}' > "$V2/_shared/forge-active"
printf -- '---\ndate: 2026-08-03\nproject: SimpleHIIT\n---\n' > "$V2/PERSO/forge/current-checkpoint.md"
out=$(FORGE_CONF_OVERRIDE="$C2" "$SCRIPT" reconcile-marker 2>&1)
assert_contains "warns when own checkpoint disagrees" "Marker mismatch" "$out"

# Checkpoint lacks a project: line → must not crash under set -e, and no warning.
V3=$(mk); C3=$(conf "$V3")
printf '{"session_id":"s","project":"forge","started_at":"x","tmux_pane":null}' > "$V3/_shared/forge-active"
printf -- '---\ndate: 2026-08-03\n---\n' > "$V3/PERSO/forge/current-checkpoint.md"
out=$(FORGE_CONF_OVERRIDE="$C3" "$SCRIPT" reconcile-marker 2>&1); rc=$?
assert_eq "no project: line -> exit 0 (no crash)" "0" "$rc"
assert_absent "no spurious warning without project: line" "Marker mismatch" "$out"

echo; echo "Pass: $PASS  Fail: $FAIL"; [ "$FAIL" -eq 0 ]
