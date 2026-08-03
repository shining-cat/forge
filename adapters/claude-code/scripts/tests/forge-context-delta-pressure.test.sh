#!/usr/bin/env bash
# Delta-aware checkpoint pressure — state helpers (Task 2).
# Covers pressure_pulse idle banking / continuous-work zero / baseline rebase,
# and get_active_age_minutes subtraction + clamp. Drives the helpers through the
# TEST-ONLY `pressure-pulse` and `get-active-age` dispatch affordances.
# bash-3.2-safe, mirrors forge-context-reconcile-marker.test.sh scaffolding.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../forge-context.sh"
PASS=0; FAIL=0
assert_eq() { local n="$1" exp="$2" act="$3"
  if [ "$exp" = "$act" ]; then echo "  ✓ $n"; PASS=$((PASS+1))
  else echo "  ✗ $n — expected [$exp] got [$act]"; FAIL=$((FAIL+1)); fi; }
assert_range() { local n="$1" lo="$2" hi="$3" act="$4"
  if [ "$act" -ge "$lo" ] && [ "$act" -le "$hi" ]; then echo "  ✓ $n"; PASS=$((PASS+1))
  else echo "  ✗ $n — expected [$lo..$hi] got [$act]"; FAIL=$((FAIL+1)); fi; }

mk() { local v; v=$(mktemp -d); mkdir -p "$v/_shared" "$v/PERSO/forge"; echo "$v"; }
# conf appends IDLE_GAP_MIN=10 for deterministic banking.
conf() { local v="$1" c; c=$(mktemp)
  printf 'VAULT_PATH=%s\nFORGE_REPO=%s\nIDLE_GAP_MIN=10\n' \
    "$v" "$(cd "$SCRIPT_DIR/../../../.." && pwd)" > "$c"; echo "$c"; }
marker() { printf '{"session_id":"s","project":"forge","started_at":"x","tmux_pane":null}' > "$1/_shared/forge-active"; }
psfile() { echo "$1/_shared/.forge-pressure-state"; }
hbfile() { echo "$1/_shared/.forge-heartbeat"; }
# set_mtime_ago FILE SECONDS — set FILE's mtime to now-SECONDS (BSD/macOS touch).
set_mtime_ago() { local f="$1" secs="$2" ep; ep=$(( $(date +%s) - secs ))
  touch -t "$(date -r "$ep" '+%Y%m%d%H%M.%S')" "$f"; }
ps_get() { grep "^$2=" "$(psfile "$1")" 2>/dev/null | cut -d= -f2-; }

echo "=== delta-pressure ==="

# 1. Idle banking: heartbeat 20min ago, IDLE_GAP_MIN=10 → gap banked (~1200s).
V=$(mk); C=$(conf "$V"); marker "$V"
: > "$(hbfile "$V")"; set_mtime_ago "$(hbfile "$V")" 1200
FORGE_CONF_OVERRIDE="$C" "$SCRIPT" pressure-pulse >/dev/null 2>&1
assert_range "idle banking: ~1200s accumulated" 1140 1260 "$(ps_get "$V" idle_accum)"

# 2. Continuous work: heartbeat 2min ago (< IDLE_GAP_MIN) → idle_accum stays 0.
V=$(mk); C=$(conf "$V"); marker "$V"
: > "$(hbfile "$V")"; set_mtime_ago "$(hbfile "$V")" 120
FORGE_CONF_OVERRIDE="$C" "$SCRIPT" pressure-pulse >/dev/null 2>&1
assert_eq "continuous work: idle_accum stays 0" "0" "$(ps_get "$V" idle_accum)"

# 3. Active-age subtraction: idle_delta=35min, raw 40 → 5.
V=$(mk); C=$(conf "$V"); marker "$V"
printf 'idle_accum=2100\nckpt_idle_base=0\n' > "$(psfile "$V")"
out=$(FORGE_CONF_OVERRIDE="$C" "$SCRIPT" get-active-age 40 ckpt 2>/dev/null)
assert_eq "active age = raw 40 - idle 35 = 5" "5" "$out"

# 4. Clamp: idle_delta=40min, raw 3 → 0 (never negative).
V=$(mk); C=$(conf "$V"); marker "$V"
printf 'idle_accum=2400\nckpt_idle_base=0\n' > "$(psfile "$V")"
out=$(FORGE_CONF_OVERRIDE="$C" "$SCRIPT" get-active-age 3 ckpt 2>/dev/null)
assert_eq "active age clamps at 0" "0" "$out"

# 5. Baseline rebase: checkpoint mtime advances past ckpt_seen → ckpt_idle_base
#    snapshots the current accumulator. Heartbeat recent so idle_accum is stable.
V=$(mk); C=$(conf "$V"); marker "$V"
printf 'idle_accum=500\nckpt_seen_mtime=1\nckpt_idle_base=0\n' > "$(psfile "$V")"
: > "$(hbfile "$V")"                              # heartbeat now → no banking
printf -- '---\ndate: 2026-08-03\nproject: forge\n---\n' > "$V/PERSO/forge/current-checkpoint.md"  # mtime now > 1
FORGE_CONF_OVERRIDE="$C" "$SCRIPT" pressure-pulse >/dev/null 2>&1
assert_eq "rebase: idle_accum unchanged (recent heartbeat)" "500" "$(ps_get "$V" idle_accum)"
assert_eq "rebase: ckpt_idle_base == idle_accum" "$(ps_get "$V" idle_accum)" "$(ps_get "$V" ckpt_idle_base)"

# 6. Fresh session (no heartbeat) behaves like today: no banking, idle_accum 0.
V=$(mk); C=$(conf "$V"); marker "$V"
FORGE_CONF_OVERRIDE="$C" "$SCRIPT" pressure-pulse >/dev/null 2>&1
assert_eq "fresh session: idle_accum 0" "0" "$(ps_get "$V" idle_accum)"
assert_eq "fresh session: heartbeat now exists" "yes" "$([ -f "$(hbfile "$V")" ] && echo yes || echo no)"

# 7. Clamp on skewed (future) heartbeat mtime: gap clamped ≥0, no banking.
V=$(mk); C=$(conf "$V"); marker "$V"
: > "$(hbfile "$V")"; touch -t "$(date -r "$(( $(date +%s) + 3600 ))" '+%Y%m%d%H%M.%S')" "$(hbfile "$V")"
FORGE_CONF_OVERRIDE="$C" "$SCRIPT" pressure-pulse >/dev/null 2>&1
assert_eq "future heartbeat: idle_accum stays 0" "0" "$(ps_get "$V" idle_accum)"

echo; echo "Pass: $PASS  Fail: $FAIL"; [ "$FAIL" -eq 0 ]
