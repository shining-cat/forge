#!/usr/bin/env python3
"""Activity logging for wellness-coach. Appends timestamped entries and trims old ones."""
import os
import time

DEFAULT_ACTIVITY_LOG_PATH = os.path.expanduser("~/.claude/wellness-activity-log.md")


def log_event(prefs, event_type, description, changes=None):
    """Append a timestamped entry to the activity log.

    event_type: reminder, break-ack, strike, strike-cleared, welcome-back
    description: one-line summary
    changes: dict of {field: "old → new"} or None
    """
    log_path = prefs.get("activity_log_path", DEFAULT_ACTIVITY_LOG_PATH)
    timestamp = time.strftime("%Y-%m-%d %H:%M")

    entry = f"\n### {timestamp} — {event_type}\n{description}\n"
    if changes:
        items = ", ".join(f"{k}: {v}" for k, v in changes.items())
        entry += f"- **Changed:** {items}\n"

    try:
        with open(log_path, "a") as f:
            f.write(entry)
    except OSError:
        pass  # logging must never break the hook

    _maybe_trim_log(log_path)


def _maybe_trim_log(log_path):
    """Remove entries older than 24h. Checked once per day via sidecar marker."""
    trim_marker = log_path + ".trimmed"
    today = time.strftime("%Y-%m-%d")
    try:
        with open(trim_marker, "r") as f:
            if f.read().strip() == today:
                return
    except (FileNotFoundError, OSError):
        pass

    try:
        with open(log_path, "r") as f:
            content = f.read()
    except (FileNotFoundError, OSError):
        return

    cutoff = time.time() - 86400
    lines = content.split("\n")
    result = []
    skip = False

    for line in lines:
        if line.startswith("### "):
            try:
                ts_str = line[4:20]  # "YYYY-MM-DD HH:MM"
                ts = time.mktime(time.strptime(ts_str, "%Y-%m-%d %H:%M"))
                skip = ts < cutoff
            except (ValueError, IndexError):
                skip = False
        if not skip:
            result.append(line)

    trimmed = "\n".join(result)
    if len(trimmed) < len(content):
        try:
            with open(log_path, "w") as f:
                f.write(trimmed)
        except OSError:
            pass

    try:
        with open(trim_marker, "w") as f:
            f.write(today)
    except OSError:
        pass
