#!/bin/bash
# wellness-status.sh — emit compact wellness chips for the statusline.
# Soft-fails to empty output on any error (statusline must never break).
#
# Two chips with different semantics:
#   🙆  — forward-looking schedule marker for the next micro-break reminder.
#         NOT a compliance signal — there's no signal saying "user stretched."
#         Always shows non-negative minutes; never "due", never red.
#   ☕  — real compliance signal for the next real break.
#         Backed by auto-detected break logic (system wake, activity monitor).
#         Can show "due" and triggers the chip color (yellow/red).
#
# Output formats:
#   "<color>🙆 12m  ☕ 38m\033[0m"           — normal state, color from break only
#   "<color>🙆 12m  ☕ due\033[0m"           — break overdue
#   "\033[31m⚠️ on strike\033[0m"            — strike active

# Resolve vault path from forge.conf (same pattern as statusline.sh forge integration)
FORGE_CONF="$HOME/.claude/forge.conf"
[ -f "$FORGE_CONF" ] || exit 0

VAULT_PATH=$(grep '^VAULT_PATH=' "$FORGE_CONF" | cut -d= -f2-)
[ -n "$VAULT_PATH" ] || exit 0

PREFS="$VAULT_PATH/_shared/wellness-preferences.json"
[ -f "$PREFS" ] || exit 0

# Read all needed fields in one jq call; defaults so missing fields don't crash
read_data=$(jq -r '
  [
    .last_micro_break_timestamp // "",
    .last_break_timestamp // "",
    .micro_break_interval_minutes // 0,
    .real_break_interval_minutes // 0,
    .strike_active // false
  ] | @tsv
' "$PREFS" 2>/dev/null) || exit 0

[ -n "$read_data" ] || exit 0

IFS=$'\t' read -r LAST_MICRO LAST_BREAK MICRO_INT BREAK_INT STRIKE <<< "$read_data"

# Strike state — replaces both chips with a red warning
if [ "$STRIKE" = "true" ]; then
  printf "\033[31m⚠️ on strike\033[0m"
  exit 0
fi

# Need both timestamps + intervals to render meaningful chips
if [ -z "$LAST_MICRO" ] || [ -z "$LAST_BREAK" ] || [ "$MICRO_INT" -eq 0 ] || [ "$BREAK_INT" -eq 0 ]; then
  exit 0
fi

# Compute minutes to next stretch and break — macOS date syntax
NOW_EPOCH=$(date +%s)
MICRO_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$LAST_MICRO" +%s 2>/dev/null) || exit 0
BREAK_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$LAST_BREAK" +%s 2>/dev/null) || exit 0

MICRO_NEXT_MIN=$(( (MICRO_EPOCH + MICRO_INT * 60 - NOW_EPOCH) / 60 ))
BREAK_NEXT_MIN=$(( (BREAK_EPOCH + BREAK_INT * 60 - NOW_EPOCH) / 60 ))

# Format each chip — 🙆 clamps to 0m (no overdue concept since there's no compliance signal),
# ☕ shows "due" since the break timestamp reflects an actual user action.
if [ "$MICRO_NEXT_MIN" -lt 0 ]; then
  MICRO_CHIP="🙆 0m"
else
  MICRO_CHIP="🙆 ${MICRO_NEXT_MIN}m"
fi

if [ "$BREAK_NEXT_MIN" -le 0 ]; then
  BREAK_CHIP="☕ due"
else
  BREAK_CHIP="☕ ${BREAK_NEXT_MIN}m"
fi

# Color driven by ☕ only (the real compliance signal): red if due, yellow if ≤ 5min, green otherwise.
if [ "$BREAK_NEXT_MIN" -le 0 ]; then
  COLOR="\033[31m"
elif [ "$BREAK_NEXT_MIN" -le 5 ]; then
  COLOR="\033[33m"
else
  COLOR="\033[32m"
fi

printf "${COLOR}%s  %s\033[0m" "$MICRO_CHIP" "$BREAK_CHIP"
