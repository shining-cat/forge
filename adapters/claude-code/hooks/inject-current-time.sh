#!/usr/bin/env bash
# UserPromptSubmit hook: prepends current local time to every user prompt.
# Eliminates time-guessing failures where Claude estimates elapsed time
# from checkpoint timestamps + step-duration guesses and gets it wrong.
#
# Cost: ~3ms per turn (one date(1) call) + ~15 tokens of context.
# Reliability: 100% — Claude sees the actual system time, no estimation.
#
# Format mirrors the system-reminder style so Claude treats it as authoritative
# context, not user input. The line is intentionally terse so it doesn't
# clutter the scrollback.

echo "[Current local time: $(date '+%Y-%m-%d %H:%M %Z')]"
