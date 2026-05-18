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

FULL_RESET="false"
for arg in "$@"; do
  case "$arg" in
    --full-reset) FULL_RESET="true" ;;
    -h|--help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *)
      echo "[wellness-reset] Unknown arg: $arg" >&2
      echo "[wellness-reset] Usage: wellness-reset.sh [--full-reset|-h|--help]" >&2
      exit 1
      ;;
  esac
done
export FULL_RESET

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

mode = 'Full reset' if full_reset else 'Strike reset'
if state['was_striking']:
    print(f'{mode}: strike cleared, timers reset.')
else:
    print(f'{mode}: no active strike, timers reset.')
"
