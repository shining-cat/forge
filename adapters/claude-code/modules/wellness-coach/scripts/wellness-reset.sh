#!/bin/bash
# Manual strike reset for wellness coach.
# Usage: ! ~/.claude/wellness-reset.sh

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
from preferences import read_modify_write, now_iso

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
    return prefs

read_modify_write(reset)
if state['was_striking']:
    print('Strike cleared. Timers reset. You are good to go.')
else:
    print('No active strike. Timers reset anyway.')
"
