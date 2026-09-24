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
fmtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
# nag-conf: like conf() but WITHOUT FORGE_REPO, so post-tool's daily install-drift
# note short-circuits (it needs FORGE_REPO/.git) and can't confound nag assertions.
nagconf() { local v="$1" c; c=$(mktemp)
  printf 'VAULT_PATH=%s\nIDLE_GAP_MIN=10\n' "$v" > "$c"; echo "$c"; }
# marker_started VAULT ISO — JSON marker with a real ISO8601 started_at (for the
# do_stop entry-grace parser) and session_id "s".
marker_started() { printf '{"session_id":"s","project":"forge","started_at":"%s","tmux_pane":null}' "$2" > "$1/_shared/forge-active"; }
assert_contains() { local n="$1" needle="$2" hay="$3"
  case "$hay" in *"$needle"*) echo "  ✓ $n"; PASS=$((PASS+1)) ;;
    *) echo "  ✗ $n — expected to contain [$needle] got [$hay]"; FAIL=$((FAIL+1)) ;; esac; }
assert_not_contains() { local n="$1" needle="$2" hay="$3"
  case "$hay" in *"$needle"*) echo "  ✗ $n — expected NOT to contain [$needle] got [$hay]"; FAIL=$((FAIL+1)) ;;
    *) echo "  ✓ $n"; PASS=$((PASS+1)) ;; esac; }

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

# 8. Partial state file (exists, missing keys) must NOT abort _ps_load under
#    pipefail — grep exits 1 on the absent key, `|| true` keeps the fallback.
#    Regression guard for the _ps_get_key pipefail bug (reviewer finding, 08-03).
V=$(mk); C=$(conf "$V"); marker "$V"
printf 'idle_accum=1234\n' > "$(psfile "$V")"   # only one of five keys present
: > "$(hbfile "$V")"; touch -t "$(date -r "$(( $(date +%s) - 900 ))" '+%Y%m%d%H%M.%S')" "$(hbfile "$V")"
FORGE_CONF_OVERRIDE="$C" "$SCRIPT" pressure-pulse >/dev/null 2>&1
rc=$?
assert_eq "partial state: pressure-pulse exits 0 (no pipefail abort)" "0" "$rc"
assert_range "partial state: preserved idle_accum + banked ~900s gap" 2124 2144 "$(ps_get "$V" idle_accum)"

echo
echo "=== Task 3: braindump nag uses active age (end-to-end post-tool) ==="
PT='{"session_id":"s","tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}'

# 8. Idle-suppressed: braindump 30min old, but 25min banked as idle → active age
#    5 < BRAINDUMP_INTERVAL_MIN(10) → NO "Brain dump due". bd baseline is pre-seeded
#    at the braindump's own mtime so the pulse won't rebase it away.
V=$(mk); C=$(nagconf "$V"); marker "$V"
rm -f /tmp/forge-braindump-cooldown-s
BD="$V/PERSO/forge/braindump.md"; printf 'note\n' > "$BD"; set_mtime_ago "$BD" 1800
printf 'idle_accum=0\nbd_seen_mtime=%s\nbd_idle_base=0\n' "$(fmtime "$BD")" > "$(psfile "$V")"
: > "$(hbfile "$V")"; set_mtime_ago "$(hbfile "$V")" 1500   # heartbeat 25min ago → banks idle
out=$(printf '%s' "$PT" | COPILOT_SESSION_ID=s FORGE_CONF_OVERRIDE="$C" "$SCRIPT" post-tool 2>/dev/null)
assert_not_contains "idle-banked braindump: no nag (active age 5)" "Brain dump due" "$out"

# 9. Genuine active: braindump 30min old, heartbeat fresh (no banking) → active age
#    30 >= 10 → "Brain dump due" fires.
V=$(mk); C=$(nagconf "$V"); marker "$V"
rm -f /tmp/forge-braindump-cooldown-s
BD="$V/PERSO/forge/braindump.md"; printf 'note\n' > "$BD"; set_mtime_ago "$BD" 1800
printf 'idle_accum=0\nbd_seen_mtime=%s\nbd_idle_base=0\n' "$(fmtime "$BD")" > "$(psfile "$V")"
: > "$(hbfile "$V")"; set_mtime_ago "$(hbfile "$V")" 120    # heartbeat 2min ago → no banking
out=$(printf '%s' "$PT" | COPILOT_SESSION_ID=s FORGE_CONF_OVERRIDE="$C" "$SCRIPT" post-tool 2>/dev/null)
assert_contains "continuous braindump: nag fires (active age 30)" "Brain dump due" "$out"

echo
echo "=== Task 4: checkpoint nag (do_stop) uses active age ==="
# Both stop tests satisfy A (entry grace: started_at 100min ago) + C (stop-count
# seeded at 20 → increments to 21 >= 10) so only the active-age math decides.
STARTED=$(date -j -f %s "$(( $(date +%s) - 6000 ))" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null \
         || date -d @"$(( $(date +%s) - 6000 ))" '+%Y-%m-%dT%H:%M:%S%z')

# 10. Idle-suppressed: checkpoint 70min old but 65min banked idle → active age 5
#     < 30 → do_stop does NOT block (and no "consider updating" advisory either).
V=$(mk); C=$(nagconf "$V"); marker_started "$V" "$STARTED"
printf '%s\n20\n' "$STARTED" > "$V/_shared/forge-session-stops"
CK="$V/PERSO/forge/current-checkpoint.md"
printf -- '---\ndate: 2026-08-03\nproject: forge\n---\nnote\n' > "$CK"
set_mtime_ago "$CK" 4200                                   # checkpoint 70min old
set_mtime_ago "$V/_shared/forge-active" 5400              # marker mtime older than ckpt (gap = raw age)
printf 'idle_accum=3900\nckpt_idle_base=0\n' > "$(psfile "$V")"   # 65min banked
out=$(printf '{"session_id":"s"}' | COPILOT_SESSION_ID=s FORGE_CONF_OVERRIDE="$C" "$SCRIPT" stop 2>/dev/null)
assert_not_contains "idle-banked checkpoint: no block (active age 5)" "Write a checkpoint now" "$out"

# 11. Genuine active: checkpoint 70min old, no idle banked → active age 70 >= 60 → BLOCK.
V=$(mk); C=$(nagconf "$V"); marker_started "$V" "$STARTED"
printf '%s\n20\n' "$STARTED" > "$V/_shared/forge-session-stops"
CK="$V/PERSO/forge/current-checkpoint.md"
printf -- '---\ndate: 2026-08-03\nproject: forge\n---\nnote\n' > "$CK"
set_mtime_ago "$CK" 4200
set_mtime_ago "$V/_shared/forge-active" 5400
printf 'idle_accum=0\nckpt_idle_base=0\n' > "$(psfile "$V")"
out=$(printf '{"session_id":"s"}' | COPILOT_SESSION_ID=s FORGE_CONF_OVERRIDE="$C" "$SCRIPT" stop 2>/dev/null)
assert_contains "continuous checkpoint: blocks (active age 70)" "Write a checkpoint now" "$out"

echo
echo "=== Task 5: count-based commit gate (do_gate) ==="
# A real git repo OUTSIDE the vault → skip_stale=0; commits authored after the
# checkpoint mtime are counted via `git log --since=@<ckpt_mtime>`.
gitrepo() { local d="$1"; git -C "$d" init -q >/dev/null 2>&1
  git -C "$d" config user.email t@t.dev; git -C "$d" config user.name tester; }
gateconf() { local v="$1" max="$2" c; c=$(mktemp)
  printf 'VAULT_PATH=%s\nFORGE_REPO=%s\nIDLE_GAP_MIN=10\nCOMMIT_GATE_MAX_UNLOGGED=%s\n' \
    "$v" "$(cd "$SCRIPT_DIR/../../../.." && pwd)" "$max" > "$c"; echo "$c"; }
commits() { local d="$1" n="$2" i=0; while [ "$i" -lt "$n" ]; do
  git -C "$d" commit -q --allow-empty -m "c$i"; i=$((i+1)); done; }
ckpt() { printf -- '---\ndate: 2026-08-03\nproject: forge\n---\n' > "$1"; }
DENY="commits since the last checkpoint refresh"
GATE_JSON='{"tool_input":{"command":"git -C %s commit -m x"}}'

# 12. Under limit: 3 commits, limit 5 → allow (no deny).
V=$(mk); GR=$(mktemp -d); gitrepo "$GR"
CK="$V/PERSO/forge/current-checkpoint.md"; ckpt "$CK"; set_mtime_ago "$CK" 3600
commits "$GR" 3; C=$(gateconf "$V" 5); marker "$V"
out=$(printf "$GATE_JSON" "$GR" | COPILOT_SESSION_ID=s FORGE_CONF_OVERRIDE="$C" "$SCRIPT" gate 2>/dev/null)
assert_not_contains "gate: 3 commits < limit 5 → allow" "$DENY" "$out"

# 13. At limit: 5 commits, limit 5 → deny with count-based reason.
V=$(mk); GR=$(mktemp -d); gitrepo "$GR"
CK="$V/PERSO/forge/current-checkpoint.md"; ckpt "$CK"; set_mtime_ago "$CK" 3600
commits "$GR" 5; C=$(gateconf "$V" 5); marker "$V"
out=$(printf "$GATE_JSON" "$GR" | COPILOT_SESSION_ID=s FORGE_CONF_OVERRIDE="$C" "$SCRIPT" gate 2>/dev/null)
assert_contains "gate: 5 commits >= limit 5 → deny" "5 $DENY" "$out"

# 14. Vault repo exempt: repo UNDER VAULT_PATH → skip_stale=1 → allow over limit.
V=$(mk); VR="$V/vaultrepo"; mkdir -p "$VR"; gitrepo "$VR"
CK="$V/PERSO/forge/current-checkpoint.md"; ckpt "$CK"; set_mtime_ago "$CK" 3600
commits "$VR" 8; C=$(gateconf "$V" 5); marker "$V"
out=$(printf "$GATE_JSON" "$VR" | COPILOT_SESSION_ID=s FORGE_CONF_OVERRIDE="$C" "$SCRIPT" gate 2>/dev/null)
assert_not_contains "gate: vault repo exempt (skip_stale)" "$DENY" "$out"

# 15. Fresh checkpoint: mtime AFTER all commits → 0 unlogged → allow.
V=$(mk); GR=$(mktemp -d); gitrepo "$GR"
commits "$GR" 8; sleep 1
CK="$V/PERSO/forge/current-checkpoint.md"; ckpt "$CK"   # mtime now, after commits
C=$(gateconf "$V" 5); marker "$V"
out=$(printf "$GATE_JSON" "$GR" | COPILOT_SESSION_ID=s FORGE_CONF_OVERRIDE="$C" "$SCRIPT" gate 2>/dev/null)
assert_not_contains "gate: fresh checkpoint (0 unlogged) → allow" "$DENY" "$out"

echo
echo "=== Task 6: touch-checkpoint escape hatch ==="

# 16. Appends review line + bumps mtime to now (raw age ~0).
V=$(mk); C=$(conf "$V"); marker "$V"
CK="$V/PERSO/forge/current-checkpoint.md"
printf -- '---\ndate: 2026-08-03\nproject: forge\n---\nbody\n' > "$CK"; set_mtime_ago "$CK" 3600
FORGE_CONF_OVERRIDE="$C" "$SCRIPT" touch-checkpoint >/dev/null 2>&1
assert_contains "touch: review line appended" "— no new state_" "$(cat "$CK")"
assert_range "touch: mtime bumped to now" 0 5 "$(( $(date +%s) - $(fmtime "$CK") ))"

# 17. Repeated touch does not stack review lines (exactly one). Reuses CK from #16.
FORGE_CONF_OVERRIDE="$C" "$SCRIPT" touch-checkpoint >/dev/null 2>&1
assert_eq "touch: review line does not stack" "1" "$(grep -c -- '— no new state_' "$CK")"

# 18. Baseline rebase: ckpt_idle_base := idle_accum, ckpt_seen_mtime := new mtime.
V=$(mk); C=$(conf "$V"); marker "$V"
CK="$V/PERSO/forge/current-checkpoint.md"
printf -- '---\ndate: 2026-08-03\nproject: forge\n---\nbody\n' > "$CK"; set_mtime_ago "$CK" 3600
printf 'idle_accum=800\nckpt_idle_base=0\n' > "$(psfile "$V")"
FORGE_CONF_OVERRIDE="$C" "$SCRIPT" touch-checkpoint >/dev/null 2>&1
assert_eq "touch: ckpt_idle_base rebased to idle_accum" "800" "$(ps_get "$V" ckpt_idle_base)"
assert_eq "touch: ckpt_seen_mtime == checkpoint mtime" "$(fmtime "$CK")" "$(ps_get "$V" ckpt_seen_mtime)"

# 19. Integration: a checkpoint that WOULD block do_stop no longer blocks post-touch.
V=$(mk); C=$(nagconf "$V"); marker_started "$V" "$STARTED"
printf '%s\n20\n' "$STARTED" > "$V/_shared/forge-session-stops"
CK="$V/PERSO/forge/current-checkpoint.md"
printf -- '---\ndate: 2026-08-03\nproject: forge\n---\nnote\n' > "$CK"; set_mtime_ago "$CK" 4200
set_mtime_ago "$V/_shared/forge-active" 5400
printf 'idle_accum=0\nckpt_idle_base=0\n' > "$(psfile "$V")"
FORGE_CONF_OVERRIDE="$C" "$SCRIPT" touch-checkpoint >/dev/null 2>&1
out=$(printf '{"session_id":"s"}' | COPILOT_SESSION_ID=s FORGE_CONF_OVERRIDE="$C" "$SCRIPT" stop 2>/dev/null)
assert_not_contains "touch: post-touch do_stop does not block" "Write a checkpoint now" "$out"

# 20. Only-a-review-line checkpoint: touch does not crash (set -e / grep -v empty), still one line.
V=$(mk); C=$(conf "$V"); marker "$V"
CK="$V/PERSO/forge/current-checkpoint.md"; printf '_reviewed 09:00 — no new state_\n' > "$CK"
FORGE_CONF_OVERRIDE="$C" "$SCRIPT" touch-checkpoint >/dev/null 2>&1; rc=$?
assert_eq "touch: only-review-line checkpoint → exit 0" "0" "$rc"
assert_eq "touch: still exactly one review line" "1" "$(grep -c -- '— no new state_' "$CK")"

echo; echo "Pass: $PASS  Fail: $FAIL"; [ "$FAIL" -eq 0 ]
