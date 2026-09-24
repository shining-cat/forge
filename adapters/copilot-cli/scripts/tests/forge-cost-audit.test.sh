#!/usr/bin/env bash
# Tests forge-cost-audit.py — retrospective cross-session cost profile.
#
# forge-cost-audit walks the GitHub Copilot CLI project logs (default $COPILOT_DIR/projects,
# overridable with --root for tests/portability), aggregates token usage per model,
# prices each model at its own tier, and reports where the money goes. With
# --cache-composition it buckets a model's cache-writes by the idle gap that
# preceded each write and computes the 1h-cache-TTL break-even (the analysis that
# settled the model-tiering cost posture — decision 2026-08-10-model-tiering-cost-posture).
#
# Contract:
#   - default --json: per-model {input,output,cache_write,cache_read,total,cost_usd}
#     + grand_total with pct split; models sorted by total desc.
#   - per-model pricing (opus/sonnet/haiku tiers), NOT flat Opus-tier for all.
#   - --cache-composition --json: cache_write_total, per-gap buckets, saveable
#     share, break-even 0.395, and verdict net_loss/net_saving.
#   - missing/empty root → graceful (exit 0, empty models, no crash).

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="$SCRIPT_DIR/../forge-cost-audit.py"

PASS=0; FAIL=0

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then echo "  ✓ $name"; PASS=$((PASS+1));
  else echo "  ✗ $name — expected '$expected', got '$actual'"; FAIL=$((FAIL+1)); fi
}

# Build a deterministic fixture project tree:
#   <root>/sessionA.jsonl  — opus, 3 records across 3 gap buckets
#   <root>/sessionB.jsonl  — sonnet, 1 record
setup() {
  TMP=$(mktemp -d)
  # Session A — opus. Timestamps: T0, T0+30s (<=60s), T0+30min (saveable 5min-1h).
  {
    printf '%s\n' '{"timestamp":"2026-08-01T10:00:00Z","type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":1000,"cache_read_input_tokens":0}}}'
    printf '%s\n' '{"timestamp":"2026-08-01T10:00:30Z","type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":0,"output_tokens":20,"cache_creation_input_tokens":500,"cache_read_input_tokens":200}}}'
    printf '%s\n' '{"timestamp":"2026-08-01T10:30:00Z","type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":0,"output_tokens":10,"cache_creation_input_tokens":800,"cache_read_input_tokens":300}}}'
  } > "$TMP/sessionA.jsonl"
  # Session B — sonnet, single record.
  printf '%s\n' '{"timestamp":"2026-08-01T10:00:00Z","type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":200,"output_tokens":100,"cache_creation_input_tokens":2000,"cache_read_input_tokens":500}}}' > "$TMP/sessionB.jsonl"
  # Session C — a zero-token synthetic model (noise that must be filtered out).
  printf '%s\n' '{"timestamp":"2026-08-01T10:00:00Z","type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}' > "$TMP/sessionC.jsonl"
}

teardown() { rm -rf "$TMP"; unset TMP; }

jqf() { echo "$1" | jq -r "$2"; }

echo "Check 1 — per-model token aggregation (default --json)"
setup
out="$("$AUDIT" --root "$TMP" --json 2>/dev/null)"
assert_eq "opus input"       "100"  "$(jqf "$out" '.models[] | select(.model=="claude-opus-4-8") | .input')"
assert_eq "opus output"      "80"   "$(jqf "$out" '.models[] | select(.model=="claude-opus-4-8") | .output')"
assert_eq "opus cache_write" "2300" "$(jqf "$out" '.models[] | select(.model=="claude-opus-4-8") | .cache_write')"
assert_eq "opus cache_read"  "500"  "$(jqf "$out" '.models[] | select(.model=="claude-opus-4-8") | .cache_read')"
assert_eq "sonnet input"     "200"  "$(jqf "$out" '.models[] | select(.model=="claude-sonnet-5") | .input')"
teardown

echo ""
echo "Check 2 — per-model pricing tiers (opus priced higher than sonnet for same tokens)"
setup
out="$("$AUDIT" --root "$TMP" --json 2>/dev/null)"
# opus cost = (100*15 + 80*75 + 2300*18.75 + 500*1.50)/1e6 = 0.051375
opus_cost="$(jqf "$out" '.models[] | select(.model=="claude-opus-4-8") | .cost_usd')"
# sonnet cost = (200*3 + 100*15 + 2000*3.75 + 500*0.30)/1e6 = 0.00975
sonnet_cost="$(jqf "$out" '.models[] | select(.model=="claude-sonnet-5") | .cost_usd')"
assert_eq "opus cost tier"   "0.051375" "$opus_cost"
assert_eq "sonnet cost tier" "0.00975"  "$sonnet_cost"
teardown

echo ""
echo "Check 3 — models sorted by total tokens descending"
setup
out="$("$AUDIT" --root "$TMP" --json 2>/dev/null)"
# opus total = 2980, sonnet total = 2800 → opus first
assert_eq "top model is opus" "claude-opus-4-8" "$(jqf "$out" '.models[0].model')"
teardown

echo ""
echo "Check 4 — cache-composition buckets + break-even verdict"
setup
out="$("$AUDIT" --root "$TMP" --cache-composition --json 2>/dev/null)"
assert_eq "focus model = highest cost (opus)" "claude-opus-4-8" "$(jqf "$out" '.model')"
assert_eq "cw total"          "2300" "$(jqf "$out" '.cache_write_total')"
assert_eq "session_start bkt" "1000" "$(jqf "$out" '.buckets.session_start')"
assert_eq "<=60s bucket"      "500"  "$(jqf "$out" '.buckets.le_60s')"
assert_eq "saveable bucket"   "800"  "$(jqf "$out" '.buckets.saveable_5min_1h')"
assert_eq "saveable tokens"   "800"  "$(jqf "$out" '.saveable_tokens')"
# saveable share = 800/2300 = 0.3478 < 0.395 → net_loss
assert_eq "verdict net_loss"  "net_loss" "$(jqf "$out" '.verdict')"
teardown

echo ""
echo "Check 5b — zero-token models are filtered out of the report"
setup
out="$("$AUDIT" --root "$TMP" --json 2>/dev/null)"
assert_eq "only 2 real models (synthetic dropped)" "2" "$(jqf "$out" '.models | length')"
assert_eq "no synthetic model present" "" "$(jqf "$out" '.models[] | select(.model=="<synthetic>") | .model')"
teardown

echo ""
echo "Check 6 — grand-total split is by COST, not token count"
setup
out="$("$AUDIT" --root "$TMP" --json 2>/dev/null)"
# cost by type (USD): input 0.0021, output 0.0075, cw 0.050625, cr 0.0009; total 0.061125
# cw cost share = 0.050625/0.061125 = 82.8%
assert_eq "cost_pct cache_write" "82.8" "$(jqf "$out" '.grand_total.cost_pct.cache_write')"
assert_eq "cost_pct output"      "12.3" "$(jqf "$out" '.grand_total.cost_pct.output')"
# per-model cost share: opus 0.051375/0.061125 = 84.0%
assert_eq "opus cost_pct of total" "84.0" "$(jqf "$out" '.models[] | select(.model=="claude-opus-4-8") | .cost_pct')"
teardown

echo ""
echo "Check 7 — missing/empty root is graceful (exit 0, no models)"
GHOST=$(mktemp -d); rmdir "$GHOST"  # a path that does not exist
out="$("$AUDIT" --root "$GHOST" --json 2>/dev/null)"; rc=$?
assert_eq "exit 0 on missing root" "0" "$rc"
assert_eq "empty models array"     "0" "$(jqf "$out" '.models | length')"

echo ""
echo "── Total: $PASS pass, $FAIL fail ──"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
