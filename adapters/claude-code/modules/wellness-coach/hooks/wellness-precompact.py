#!/usr/bin/env python3
"""
PreCompact hook for wellness-coach plugin.
Suggests a break during compaction idle time. Never blocks compaction.

Output JSON to stdout (PreCompact hookSpecificOutput format):
  No output         - silent (no break suggestion)
  {"hookSpecificOutput": {...}, "systemMessage": "..."}
                     - suggestion shown in conversation
"""
import json
import os
import sys

# Add plugin directory to path for preferences module
PLUGIN_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, PLUGIN_DIR)

from preferences import read_prefs, minutes_since


def main():
    prefs = read_prefs()
    if prefs is None:
        return

    coach_name = prefs.get("coach_name", "Coach")
    persona = prefs.get("persona", "playful")
    break_interval = prefs.get("real_break_interval_minutes", 45)
    last_break = prefs.get("last_break_timestamp")
    personal_notes = prefs.get("personal_notes", [])

    if not last_break:
        minutes_elapsed = 999
    else:
        minutes_elapsed = int(minutes_since(last_break))

    minutes_until_break = break_interval - minutes_elapsed

    # Pick the right message based on timing
    overdue_by = abs(minutes_until_break) if minutes_until_break <= 0 else 0

    if minutes_until_break <= 0:
        # Break is overdue
        msg = _overdue_message(coach_name, persona, overdue_by, personal_notes)
    elif minutes_until_break <= 10:
        # Break is close — nudge to take it now
        msg = _soon_message(coach_name, persona, minutes_until_break, personal_notes)
    else:
        # Break isn't due — just suggest a micro-break
        msg = _micro_message(coach_name, persona, minutes_until_break)

    output = {"systemMessage": msg}
    print(json.dumps(output))


def _pick_activity(personal_notes):
    """Pick a contextual suggestion from personal notes."""
    for note in personal_notes:
        if "standing" in note.lower() or "desk" in note.lower():
            return "toggle your desk"
        if "dog" in note.lower():
            return "take the dog out"
        if "knit" in note.lower():
            return "grab some knitting"
    return "stretch your legs"


def _overdue_message(coach_name, persona, overdue_by, notes):
    activity = _pick_activity(notes)
    if persona == "professional":
        return f"{coach_name}: Compaction running. Your break was due {overdue_by} minutes ago — good time to {activity}."
    elif persona == "character":
        return f"{coach_name}: Compaction's churning — and you're {overdue_by} minutes past your break. Go {activity}. I'll hold things down."
    else:
        return f"{coach_name}: Compaction time! Your break is overdue by {overdue_by} min. Perfect moment to {activity}!"


def _soon_message(coach_name, persona, minutes_left, notes):
    activity = _pick_activity(notes)
    if persona == "professional":
        return f"{coach_name}: Compaction running. Break due in {minutes_left} minutes — consider taking it now while waiting."
    elif persona == "character":
        return f"{coach_name}: Compaction's working, break's in {minutes_left} min — why not take it now and {activity}?"
    else:
        return f"{coach_name}: Compaction's running and break's almost due ({minutes_left} min). Go {activity} while it crunches!"


def _micro_message(coach_name, persona, minutes_left):
    if persona == "professional":
        return f"{coach_name}: Compaction running. Next break in {minutes_left} minutes. Good time to stretch."
    elif persona == "character":
        return f"{coach_name}: Compaction's grinding — stretch while you wait. Break's not for another {minutes_left} min."
    else:
        return f"{coach_name}: Compaction time! Quick stretch while it runs? Next real break in {minutes_left} min."


if __name__ == "__main__":
    main()
