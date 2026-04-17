#!/usr/bin/env python3
"""Box formatting and terminal centering for wellness-coach reminders."""
import fcntl
import os
import shutil

BOX_INNER_WIDTH = 34
BOX_CONTENT_MARGIN = 2
BOX_TEXT_WIDTH = BOX_INNER_WIDTH - BOX_CONTENT_MARGIN  # 32

REMINDER_LOCK_PATH = os.path.expanduser("~/.claude/wellness-reminder.lock")


def format_box(coach_name, lines, tier):
    """Build a bordered box string for the given tier.

    Tiers:
      micro / welcome_back — thin single-line borders (─)
      break / insist       — double-line box (═ ║)
      strike               — double-line box with header banner
    """
    w = BOX_INNER_WIDTH

    if tier in ("micro", "welcome_back"):
        name_seg = f"── {coach_name} "
        fill = max(0, w - len(name_seg))
        top = "┌" + name_seg + "─" * fill + "┐"
        bottom = "└" + "─" * w + "┘"
        body = ["│" + ("  " + ln).ljust(w)[:w] + "│" for ln in lines]
        return "\n".join([top] + body + [bottom])

    if tier == "strike":
        top = "╔" + "═" * w + "╗"
        banner_text = f"⛔  {coach_name.upper()} ON STRIKE  ⛔"
        banner = "║" + banner_text.center(w - 2) + "║"
        sep = "╠" + "═" * w + "╣"
        empty = "║" + " " * w + "║"
        bottom = "╚" + "═" * w + "╝"
        body = ["║" + ("  " + ln).ljust(w)[:w] + "║" for ln in lines]
        return "\n".join([top, banner, sep, empty] + body + [empty, bottom])

    # break / insist — double-line box with coach name
    name_seg = f"══ {coach_name} "
    fill = max(0, w - len(name_seg))
    top = "╔" + name_seg + "═" * fill + "╗"
    empty = "║" + " " * w + "║"
    bottom = "╚" + "═" * w + "╝"
    body = ["║" + ("  " + ln).ljust(w)[:w] + "║" for ln in lines]
    return "\n".join([top, empty] + body + [empty, bottom])


def center_block(block):
    """Center a multi-line block horizontally in the terminal.
    Starts with a newline so the box begins on a fresh line
    after Claude Code's 'PreToolUse:X says:' prefix."""
    try:
        term_width = shutil.get_terminal_size().columns
    except (AttributeError, ValueError):
        return "\n" + block
    box_width = BOX_INNER_WIDTH + 2
    pad = max(0, (term_width - box_width) // 2)
    prefix = " " * pad
    return "\n" + "\n".join(prefix + line for line in block.split("\n"))


def try_reminder_lock():
    """Try to acquire a non-blocking exclusive lock for reminder emission.
    Prevents duplicate reminders when parallel tool calls trigger the hook
    concurrently. Returns the open fd if acquired (keep alive until done),
    None if another hook instance already holds it."""
    try:
        fd = open(REMINDER_LOCK_PATH, "w")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except (IOError, OSError):
        return None
