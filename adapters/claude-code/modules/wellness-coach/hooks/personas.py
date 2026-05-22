#!/usr/bin/env python3
"""Persona message templates for wellness-coach reminders."""
from formatting import BOX_TEXT_WIDTH


def get_persona_messages(prefs, level, elapsed_min):
    """Return (content_lines, notification_body) for the given level/persona.

    content_lines: list of strings for the box body (each <= BOX_TEXT_WIDTH)
    notification_body: string for OS notification
    """
    persona = prefs.get("persona", "professional")
    elapsed = int(elapsed_min)
    coach_name = prefs.get("coach_name", "your wellness coach")
    break_interval = prefs.get(
        "real_break_interval_minutes",
        prefs.get("break_interval_minutes", 60),
    )
    remaining = max(0, int(break_interval - elapsed_min))

    escape = [
        "",
        f"Talk to {coach_name} or run:",
        "! ~/.claude/wellness-reset.sh",
    ]

    if persona == "professional":
        msgs = {
            "micro": (
                [f"Break in {remaining} min — stretch"],
                f"Stretch & toggle desk — break in {remaining} min",
            ),
            "break": (
                [f"{elapsed} min. Time for a break."],
                f"Time for a break — {elapsed} min",
            ),
            "insist": (
                [f"Break overdue. {elapsed} min.", "Please step away."],
                f"Break overdue — {elapsed} min",
            ),
            "strike": (
                [f"Tools paused. {elapsed} min",
                 "without a break. Step away."] + escape,
                f"Tools paused — {elapsed} min",
            ),
        }
    elif persona == "playful":
        msgs = {
            "micro": (
                [f"Break in {remaining} min — stretch!"],
                f"Stretch & toggle desk — break in {remaining} min",
            ),
            "break": (
                [f"{elapsed} min! Time to step away."],
                f"Time to step away — {elapsed} min",
            ),
            "insist": (
                [f"Hey, {elapsed} min now!",
                 "I said break. I meant it."],
                f"Seriously, break! — {elapsed} min",
            ),
            "strike": (
                [f"Nope. Tools down. {elapsed} min is",
                 "too long. Go take a break."] + escape,
                "On strike! Take a break.",
            ),
        }
    else:  # character
        msgs = {
            "micro": (
                [f"Break in {remaining} min. Stretch."],
                f"Blink. Breathe. Move. — break in {remaining} min",
            ),
            "break": (
                [f"{elapsed} min. Your posture is",
                 "terrible. You know the drill."],
                "Your coach demands attention",
            ),
            "insist": (
                ["I told you. I have receipts.",
                 f"{elapsed} min. Don't make me strike."],
                "Last warning before strike!",
            ),
            "strike": (
                ["That's it. I'm on strike.",
                 f"{elapsed} min and counting.",
                 "Go. Walk. Now."] + escape,
                "ON STRIKE. Go outside.",
            ),
        }

    content, notif = msgs.get(level, ([], ""))
    return [ln[:BOX_TEXT_WIDTH] for ln in content], notif


def get_welcome_back_lines(persona, tier="real"):
    """Return content lines for the welcome-back box.

    `tier` is "real" or "micro" — micro is shown for short locks (typically
    2–10 min) that reset the stretch timer but not the real-break timer.
    The micro copy is intentionally lighter so the user knows the break was
    noted but doesn't think the real-break countdown got reset.
    """
    if tier == "micro":
        if persona == "playful":
            return ["Short break noted!", "Stretch timer reset."]
        elif persona == "character":
            return ["Quick step away — I saw.", "Stretch reset; break still due."]
        return ["Short break detected.", "Micro-break credited."]

    # Real break (default).
    if persona == "playful":
        return ["Welcome back! Break credited."]
    elif persona == "character":
        return ["You were gone. I noticed.", "Break credited."]
    return ["Break detected. Credited."]
