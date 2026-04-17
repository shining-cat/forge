#!/bin/bash
# Manual strike reset for wellness coach.
# Usage: ! ~/.claude/vigor-reset.sh

PREFS_FILE="$HOME/.claude/wellness-preferences.json"

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
