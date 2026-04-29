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

NOW=$(date +"%Y-%m-%dT%H:%M:%S")

# Use python3 for reliable JSON manipulation
python3 -c "
import json, sys

with open('$PREFS_FILE', 'r') as f:
    prefs = json.load(f)

was_striking = prefs.get('strike_active', False)
prefs['strike_active'] = False
prefs['last_break_timestamp'] = '$NOW'
prefs['snooze_count'] = 0
history = prefs.get('break_history', [])
history.append({'timestamp': '$NOW', 'type': 'real'})
prefs['break_history'] = history

with open('$PREFS_FILE', 'w') as f:
    json.dump(prefs, f, indent=2)

if was_striking:
    print('Strike cleared. Timers reset. You are good to go.')
else:
    print('No active strike. Timers reset anyway.')
"
