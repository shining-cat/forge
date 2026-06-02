#!/bin/bash
# Manual wellness reset.
#
# Usage:
#   ! ~/.claude/skills/wellness-coach/scripts/wellness-reset.sh
#       Strike reset (default): clears strike_active, sets last_break_timestamp
#       to now, zeros snooze_count, appends a 'real' break to history.
#       Leaves last_micro_break_timestamp, last_reminder_timestamp, and
#       strike_cleared_at untouched — keeps the natural cadence intact.
#
#   ! ~/.claude/skills/wellness-coach/scripts/wellness-reset.sh --full-reset
#       Full reset: above PLUS sets last_micro_break_timestamp,
#       last_reminder_timestamp, and strike_cleared_at to now. Use after a
#       manual silence (e.g. pushed timestamps to a future time) to restore
#       Pip to a fully normal cadence starting from now.
#
#   ! ~/.claude/skills/wellness-coach/scripts/wellness-reset.sh --if-cold-start
#       Cold-start guard: if WELLNESS_ENABLED=true in forge.conf AND the
#       gap since last Forge signal exceeds WELLNESS_COLD_START_HOURS (default
#       4h), run --full-reset and emit a one-line "Wellness reset — ..." note.
#       Otherwise silent no-op (exit 0). Invoked by Forge SKILL.md step 0a.

FULL_RESET="false"
IF_COLD_START="false"
for arg in "$@"; do
  case "$arg" in
    --full-reset) FULL_RESET="true" ;;
    --if-cold-start) IF_COLD_START="true" ;;
    -h|--help)
      sed -n '2,21p' "$0"
      exit 0
      ;;
    *)
      echo "[wellness-reset] Unknown arg: $arg" >&2
      echo "[wellness-reset] Usage: wellness-reset.sh [--full-reset|--if-cold-start|-h|--help]" >&2
      exit 1
      ;;
  esac
done

# --if-cold-start: gate on WELLNESS_ENABLED + gap-since-last-signal. Self-contained
# so the Forge SKILL only needs one Bash call (and this script is on the strike
# exemption list, so cold-start can run BEFORE step 0 unblocks the strike).
if [ "$IF_COLD_START" = "true" ]; then
  FORGE_CONF="$HOME/.claude/forge.conf"
  [ -f "$FORGE_CONF" ] || exit 0
  WELLNESS_ENABLED=$(grep '^WELLNESS_ENABLED=' "$FORGE_CONF" | cut -d= -f2- | tr -d '[:space:]')
  [ "$WELLNESS_ENABLED" = "true" ] || exit 0
  WELLNESS_COLD_START_HOURS=$(grep '^WELLNESS_COLD_START_HOURS=' "$FORGE_CONF" | cut -d= -f2- | tr -d '[:space:]')
  [ -z "$WELLNESS_COLD_START_HOURS" ] && WELLNESS_COLD_START_HOURS=4
  # Tier-2 threshold: above this, the gap reads as a fresh start (overnight, weekend,
  # multi-day) rather than a break credited mid-workday. Independent from
  # COLD_START_HOURS — that one gates whether the message fires at all; this one
  # tiers the message wording.
  WELLNESS_DAY_START_HOURS=$(grep '^WELLNESS_DAY_START_HOURS=' "$FORGE_CONF" | cut -d= -f2- | tr -d '[:space:]')
  [ -z "$WELLNESS_DAY_START_HOURS" ] && WELLNESS_DAY_START_HOURS=6
  GAP_SCRIPT="$HOME/.claude/scripts/forge-gap-since-last-signal.sh"
  [ -x "$GAP_SCRIPT" ] || exit 0
  GAP_SECONDS=$("$GAP_SCRIPT" 2>/dev/null)
  # Sentinel: no signals yet (fresh install / wiped vault) → don't reset, let the
  # user take their first break on schedule.
  [ "$GAP_SECONDS" = "999999999" ] && exit 0
  THRESHOLD=$(( WELLNESS_COLD_START_HOURS * 3600 ))
  [ "$GAP_SECONDS" -ge "$THRESHOLD" ] 2>/dev/null || exit 0
  # Promote to full reset and emit the cold-start note after the reset succeeds.
  FULL_RESET="true"
  COLD_START_HOURS=$(( GAP_SECONDS / 3600 ))
  COLD_START_MINUTES=$(( (GAP_SECONDS % 3600) / 60 ))
  # Day-start tier: gap large enough that "break credited" framing reads wrong.
  DAY_START_THRESHOLD=$(( WELLNESS_DAY_START_HOURS * 3600 ))
  if [ "$GAP_SECONDS" -ge "$DAY_START_THRESHOLD" ] 2>/dev/null; then
    export DAY_START_VARIANT=true
  fi
  export COLD_START_HOURS COLD_START_MINUTES
fi
export FULL_RESET
export IF_COLD_START

# Resolve preferences path from forge.conf VAULT_PATH (see preferences.py).
# Falls back to legacy ~/.claude/ location with a warning if forge.conf is missing.
LEGACY_PREFS="$HOME/.claude/wellness-preferences.json"
FORGE_CONF="$HOME/.claude/forge.conf"
if [ -f "$FORGE_CONF" ]; then
  VAULT_PATH=$(grep '^VAULT_PATH=' "$FORGE_CONF" | cut -d= -f2- | tr -d '[:space:]')
  if [ -n "$VAULT_PATH" ]; then
    PREFS_FILE="$VAULT_PATH/_shared/wellness-preferences.json"
  else
    echo "[wellness-reset] VAULT_PATH not set in forge.conf — using $LEGACY_PREFS" >&2
    PREFS_FILE="$LEGACY_PREFS"
  fi
else
  echo "[wellness-reset] forge.conf not found — using $LEGACY_PREFS" >&2
  PREFS_FILE="$LEGACY_PREFS"
fi

if [ ! -f "$PREFS_FILE" ]; then
  echo "No wellness preferences found. Nothing to reset."
  exit 0
fi

# Use python3 with the preferences module for the prefs/runtime split.
# read_modify_write handles atomic file ops + the split between
# wellness-preferences.json and wellness-runtime.json transparently.
PYTHONPATH="$HOME/.claude/skills/wellness-coach/hooks" python3 -c "
import os
from preferences import read_modify_write, now_iso

full_reset = os.environ.get('FULL_RESET') == 'true'
if_cold_start = os.environ.get('IF_COLD_START') == 'true'

# Closure captures was_striking before mutation — avoids persisting a transient
# signal as a stored field (which would land in PREFS as untracked-by-design noise).
state = {'was_striking': False}

def reset(prefs):
    state['was_striking'] = prefs.get('strike_active', False)
    now = now_iso()
    prefs['strike_active'] = False
    prefs['last_break_timestamp'] = now
    prefs['snooze_count'] = 0
    history = prefs.get('break_history', []) or []
    history.append({'timestamp': now, 'type': 'real'})
    prefs['break_history'] = history
    if full_reset:
        # Restore all timer-related state to 'now' — for after a manual silence
        # that pushed timestamps into the future. Default reset leaves these
        # alone to preserve the natural micro-break cadence.
        prefs['last_micro_break_timestamp'] = now
        prefs['last_reminder_timestamp'] = now
        prefs['strike_cleared_at'] = now
    return prefs

read_modify_write(reset)

if if_cold_start:
    # Single line, designed to surface verbatim in Forge entry summary.
    # Two tiers: short cold start (4h ≤ gap < WELLNESS_DAY_START_HOURS) reads as a
    # break credited; longer gaps (overnight, weekend, multi-day) read as a fresh
    # start where 'credited a break' would imply work the user didn't do.
    h = os.environ.get('COLD_START_HOURS', '?')
    m = os.environ.get('COLD_START_MINUTES', '?')
    day_start = os.environ.get('DAY_START_VARIANT') == 'true'
    if day_start:
        print(f'Welcome back — fresh start after {h}h{m}m away.')
    else:
        print(f'Wellness reset — Forge idle for {h}h{m}m, break clock zeroed.')
else:
    mode = 'Full reset' if full_reset else 'Strike reset'
    if state['was_striking']:
        print(f'{mode}: strike cleared, timers reset.')
    else:
        print(f'{mode}: no active strike, timers reset.')
"
