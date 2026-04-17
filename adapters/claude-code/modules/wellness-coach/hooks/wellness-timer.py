#!/usr/bin/env python3
"""
PreToolUse hook for wellness-coach plugin.
Runs before every tool call. Checks elapsed time since last break.

Exit codes:
  0 = allow
  2 = block (strike mode)

Output JSON to stdout (PreToolUse hookSpecificOutput format):
  No output                    - implicit allow (silent)
  {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}, "systemMessage": "..."}
                               - allow with message shown in conversation
  {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "..."}}
                               - block tool execution (strike)
"""
import fcntl
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone

# Add plugin directory to path for preferences module
PLUGIN_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, PLUGIN_DIR)

from preferences import (
    read_prefs, write_prefs, read_modify_write, minutes_since, now_iso,
    read_idle_log, find_last_screen_off_break, get_system_wake_time,
    get_system_boot_time, get_current_screen_state,
)

SCRIPTS_DIR = os.path.join(os.path.dirname(PLUGIN_DIR), "scripts")
REMINDER_COOLDOWN_MINUTES = 5

BOX_INNER_WIDTH = 34
BOX_CONTENT_MARGIN = 2
BOX_TEXT_WIDTH = BOX_INNER_WIDTH - BOX_CONTENT_MARGIN  # 32

CALENDAR_CACHE_PATH = os.path.expanduser("~/.claude/wellness-calendar-cache.json")
CALENDAR_CACHE_TTL_MINUTES = 15

DEFAULT_ACTIVITY_LOG_PATH = os.path.expanduser("~/.claude/wellness-activity-log.md")


# ── Activity logging ──────────────────────────────────────

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

    _maybe_trim_log(prefs, log_path)


def _maybe_trim_log(prefs, log_path):
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


# ── Box formatting ─────────────────────────────────────────

def format_box(coach_name, lines, tier):
    """Build a bordered box string for the given tier.

    Tiers:
      micro / welcome_back — thin single-line borders (─)
      break / insist       — double-line box (═ ║)
      strike               — double-line box with header banner
    """
    w = BOX_INNER_WIDTH
    total = w + 2  # total line width including border chars

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
        # Pad to w-2 chars: two emoji render as 2 display columns each,
        # so using 2 fewer chars produces the correct visual width of w.
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


REMINDER_LOCK_PATH = os.path.expanduser("~/.claude/wellness-reminder.lock")


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


# ── Context enrichment (real breaks only) ──────────────────

def fetch_weather(city):
    """Fetch weather via weather.sh script. Returns dict or None."""
    script = os.path.join(SCRIPTS_DIR, "weather.sh")
    if not os.path.exists(script) or not city:
        return None
    try:
        result = subprocess.run(
            [script, city], capture_output=True, text=True, timeout=3
        )
        if result.returncode == 0 and result.stdout.strip():
            return json.loads(result.stdout.strip())
    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError):
        pass
    return None


def _read_stale_cache():
    """Read calendar cache regardless of age."""
    try:
        with open(CALENDAR_CACHE_PATH) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None


def fetch_or_read_calendar_cache():
    """Read calendar cache if fresh (< 15 min), fetch live if stale."""
    cache = _read_stale_cache()
    if cache and cache.get("fetched_at"):
        if minutes_since(cache["fetched_at"]) < CALENDAR_CACHE_TTL_MINUTES:
            return cache

    try:
        token = subprocess.run(
            ["gcloud", "auth", "application-default", "print-access-token"],
            capture_output=True, text=True, timeout=3
        ).stdout.strip()
        if not token:
            return cache

        project = subprocess.run(
            ["gcloud", "config", "get-value", "project"],
            capture_output=True, text=True, timeout=2
        ).stdout.strip()

        now_utc = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        eod_utc = datetime.now(timezone.utc).replace(
            hour=23, minute=59
        ).strftime("%Y-%m-%dT%H:%M:%SZ")

        url = (
            "https://www.googleapis.com/calendar/v3/calendars/primary/events"
            f"?maxResults=5&timeMin={now_utc}&timeMax={eod_utc}"
            "&orderBy=startTime&singleEvents=true"
        )
        result = subprocess.run(
            ["curl", "-sS",
             "-H", f"Authorization: Bearer {token}",
             "-H", f"x-goog-user-project: {project}",
             url],
            capture_output=True, text=True, timeout=4
        )
        if result.returncode != 0:
            return cache

        data = json.loads(result.stdout)
        events = data.get("items", [])
        next_event = None
        events_today = []
        for e in events:
            # Skip events the user has declined
            attendees = e.get("attendees", [])
            if attendees:
                me = next((a for a in attendees if a.get("self")), None)
                if me and me.get("responseStatus") == "declined":
                    continue
            start = e.get("start", {}).get(
                "dateTime", e.get("start", {}).get("date", "")
            )
            entry = {"summary": e.get("summary", "Meeting"), "start": start}
            events_today.append(entry)
            if not next_event:
                next_event = entry

        new_cache = {
            "fetched_at": now_iso(),
            "next_event": next_event,
            "events_today": events_today,
        }
        try:
            with open(CALENDAR_CACHE_PATH, "w") as f:
                json.dump(new_cache, f)
        except OSError:
            pass
        return new_cache

    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError):
        return cache


def get_context_lines(prefs):
    """Assemble weather/calendar/energy context lines for real breaks."""
    lines = []

    # Weather
    if prefs.get("weather_enabled"):
        weather = fetch_weather(prefs.get("weather_city", ""))
        if weather:
            temp = weather.get("temp_c", "?")
            condition = weather.get("condition", "").lower()
            outdoor = weather.get("is_outdoor_friendly", False)
            min_temp = prefs.get("min_outdoor_temp_c", 5)
            if outdoor and isinstance(temp, (int, float)) and temp >= min_temp:
                lines.append(f"{temp}°C {condition} — go outside?")
            else:
                lines.append(f"{temp}°C {condition} — stretch indoors")

    # Calendar
    if prefs.get("calendar_enabled"):
        cal = fetch_or_read_calendar_cache()
        if cal and cal.get("next_event"):
            event = cal["next_event"]
            summary = event.get("summary", "Meeting")
            start_str = event.get("start", "")
            if start_str:
                try:
                    start_clean = start_str.replace("Z", "+00:00")
                    start_dt = datetime.fromisoformat(start_clean)
                    now = datetime.now(timezone.utc)
                    if start_dt.tzinfo is None:
                        start_dt = start_dt.replace(tzinfo=timezone.utc)
                    diff_min = int((start_dt - now).total_seconds() / 60)
                    if 0 < diff_min <= 120:
                        max_sum = BOX_TEXT_WIDTH - len(f" in {diff_min} min.")
                        lines.append(
                            f"{summary[:max_sum]} in {diff_min} min."
                        )
                except (ValueError, TypeError):
                    pass

    # Energy patterns (time of day)
    hour = datetime.now().hour
    energy = prefs.get("energy_patterns", {})
    if 12 <= hour <= 14 and energy.get("after_lunch") == "low":
        lines.append("Post-lunch dip — walk it off")
    elif hour >= 16 and energy.get("evening") == "low":
        lines.append("Evening — move around a bit")

    return [ln[:BOX_TEXT_WIDTH] for ln in lines]


# ── Notifications ──────────────────────────────────────────

def notify(title, body):
    """Send macOS notification."""
    script = os.path.join(SCRIPTS_DIR, "notify.sh")
    if os.path.exists(script):
        subprocess.run([script, title, body], capture_output=True, timeout=5)


# ── Persona messages ───────────────────────────────────────

def get_persona_messages(prefs, level, elapsed_min):
    """Return (content_lines, notification_body) for the given level/persona.

    content_lines: list of strings for the box body (each <= 32 chars)
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
        "! ~/.claude/vigor-reset.sh",
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


def get_welcome_back_lines(persona):
    """Return content lines for the welcome-back box."""
    if persona == "playful":
        return ["Welcome back! Break credited."]
    elif persona == "character":
        return ["You were gone. I noticed.", "Break credited."]
    return ["Break detected. Credited."]


# ── Hook logic ─────────────────────────────────────────────

def determine_level(prefs, elapsed_min):
    """Determine which escalation level applies."""
    micro_interval = prefs.get("micro_break_interval_minutes", 25)
    break_interval = prefs.get(
        "real_break_interval_minutes",
        prefs.get("break_interval_minutes", 60),
    )
    strike_delay = prefs.get("strike_delay_minutes", 15)
    interruption = prefs.get(
        "insistence_level",
        prefs.get("interruption_level", "escalating_strike"),
    )

    if (elapsed_min >= break_interval + strike_delay
            and interruption == "escalating_strike"):
        return "strike"
    if (elapsed_min >= break_interval + 10
            and interruption in ("escalating", "escalating_strike")):
        return "insist"
    if elapsed_min >= break_interval:
        return "break"

    since_micro = minutes_since(prefs.get("last_micro_break_timestamp"))
    if since_micro >= micro_interval:
        return "micro"

    return None


def read_hook_input():
    """Read and parse the hook's stdin payload once. Returns dict or {}."""
    try:
        return json.load(sys.stdin)
    except (json.JSONDecodeError, EOFError):
        return {}


def is_wellness_coach_skill(hook_input):
    """Check if the current tool call is invoking the wellness-coach skill."""
    tool_name = hook_input.get("tool_name", "")
    tool_input = hook_input.get("tool_input", {})
    if tool_name == "Skill" and tool_input.get("skill") == "wellness-coach":
        return True
    return False


def is_vault_write(hook_input):
    """Check if the tool call is a Write/Edit targeting the vault.

    Vault writes are automated context preservation (checkpoints, decisions)
    and must not be blocked by strike — blocking them creates a deadlock
    where the system can't save state during enforced breaks.
    """
    tool_name = hook_input.get("tool_name", "")
    tool_input = hook_input.get("tool_input", {})
    file_path = tool_input.get("file_path", "")
    # Read vault path from forge.conf
    vault_path = ""
    conf_path = os.path.expanduser("~/.claude/forge.conf")
    if os.path.exists(conf_path):
        with open(conf_path) as f:
            for line in f:
                if line.startswith("VAULT_PATH="):
                    vault_path = line.strip().split("=", 1)[1]
                    break
    if not vault_path:
        return False
    return tool_name in ("Write", "Edit") and vault_path in file_path


def emit_allow(message):
    """Print allow JSON with systemMessage and exit."""
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
        },
        "systemMessage": message,
    }))
    sys.exit(0)


def emit_deny(short_reason, detail_message):
    """Print deny JSON and exit.
    short_reason: one-liner shown in Claude Code's error callouts.
    detail_message: full formatted message shown via systemMessage."""
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": short_reason,
        },
        "systemMessage": detail_message,
    }))
    sys.exit(2)


def main():
    prefs = read_prefs()
    if prefs is None:
        sys.exit(0)

    coach_name = prefs.get("coach_name", "Wellness Coach")

    # Read hook input (stdin) once — used for exemption checks below
    hook_input = read_hook_input()

    # Always allow the wellness-coach skill through — even during strike.
    # Only clear strike_active so the skill can run. Don't reset the break
    # timer — the skill's break acknowledgment sets the real timestamp
    # when the user actually takes the break. Set strike_cleared_at to
    # give a 10-minute grace period before the hook can re-strike.
    if is_wellness_coach_skill(hook_input):
        if prefs.get("strike_active"):
            old_snooze = prefs.get("snooze_count", 0)
            def clear_strike(p):
                p["strike_active"] = False
                p["strike_cleared_at"] = now_iso()
                p["snooze_count"] = 0
                return p
            read_modify_write(clear_strike)
            log_event(prefs, "strike-cleared",
                "Strike cleared via wellness skill invocation.",
                {"strike_active": "true → false",
                 "snooze_count": f"{old_snooze} → 0"})
        sys.exit(0)

    # Strike already active — block every tool call
    # (no dedup lock here — every denied call must block)
    # No log_event here — fires on every tool call during strike, too noisy.
    # Strike start/end are logged at trigger and clear points.
    if prefs.get("strike_active"):
        # Exempt vault writes — context preservation takes priority over
        # break enforcement. Blocking these creates a deadlock where the
        # system can't save checkpoints during enforced breaks.
        if is_vault_write(hook_input):
            sys.exit(0)

        elapsed = minutes_since(prefs.get("last_break_timestamp"))
        lines, _ = get_persona_messages(prefs, "strike", elapsed)
        box = format_box(coach_name, lines, "strike")
        emit_deny(
            f"On strike — {int(elapsed)} min without a break",
            center_block(box),
        )

    # Auto-detect breaks from activity monitoring
    auto_break = None
    last_break = prefs.get("last_break_timestamp")

    if prefs.get("activity_monitor_enabled"):
        samples = read_idle_log()
        if samples:
            # Race condition fix: the hook can fire before the sampler
            # records the user's return (screen-on sample). If the current
            # screen state is on/unlocked but the most recent sample is
            # off/locked, synthesize a virtual on-sample so
            # find_last_screen_off_break can detect the transition.
            last_sample = max(samples, key=lambda s: s["t"])
            if last_sample["display"] == "off" or last_sample.get("locked"):
                current = get_current_screen_state()
                if current and current["display"] == "on" and not current["locked"]:
                    samples.append({
                        "t": time.time(),
                        "display": "on",
                        "locked": False,
                    })
            auto_break = find_last_screen_off_break(samples)

    if not auto_break and last_break:
        wake_time = get_system_wake_time()
        if wake_time and wake_time > last_break:
            if minutes_since(last_break) - minutes_since(wake_time) >= 5:
                auto_break = wake_time

        if not auto_break:
            boot_time = get_system_boot_time()
            if boot_time and boot_time > last_break:
                if minutes_since(last_break) - minutes_since(boot_time) >= 5:
                    auto_break = boot_time

    # Apply auto-detected break
    if auto_break and (not last_break or auto_break > last_break):
        old_strike = prefs.get("strike_active", False)
        old_snooze = prefs.get("snooze_count", 0)
        def credit_break(p):
            p["last_break_timestamp"] = auto_break
            p["last_micro_break_timestamp"] = auto_break
            p["strike_active"] = False
            p["strike_cleared_at"] = None
            p["snooze_count"] = 0
            return p
        read_modify_write(credit_break)
        prefs["last_break_timestamp"] = auto_break
        prefs["strike_active"] = False
        prefs["snooze_count"] = 0

        changes = {"last_break_timestamp": f"{last_break} → {auto_break}"}
        if old_strike:
            changes["strike_active"] = "true → false"
        if old_snooze:
            changes["snooze_count"] = f"{old_snooze} → 0"
        log_event(prefs, "break-ack",
            f"Auto-detected break. Credited at {auto_break}.", changes)

        # Welcome-back message if user just returned (within 5 min).
        # Acquire dedup lock to prevent duplicate boxes from parallel tool calls.
        try:
            break_end_epoch = time.mktime(
                time.strptime(auto_break, "%Y-%m-%dT%H:%M:%S")
            )
            if int((time.time() - break_end_epoch) / 60) <= 5:
                lock_fd = try_reminder_lock()
                if lock_fd is not None:
                    persona = prefs.get("persona", "professional")
                    wb_lines = get_welcome_back_lines(persona)
                    box = format_box(coach_name, wb_lines, "welcome_back")
                    log_event(prefs, "welcome-back",
                        "Welcome-back shown — user returned from auto-detected break.")
                    emit_allow(center_block(box))
        except (ValueError, TypeError, OverflowError):
            pass

    elapsed = minutes_since(prefs.get("last_break_timestamp"))
    level = determine_level(prefs, elapsed)

    if level is None:
        sys.exit(0)

    # Grace period after skill-cleared strike. When the user tells the
    # coach they're leaving for a break, the hook clears strike_active
    # without resetting the timer. Suppress re-striking for 10 minutes
    # to give the user time to actually leave.
    STRIKE_GRACE_MINUTES = 10
    if level == "strike" and prefs.get("strike_cleared_at"):
        since_cleared = minutes_since(prefs["strike_cleared_at"])
        if since_cleared < STRIKE_GRACE_MINUTES:
            sys.exit(0)

    # Reminder cooldown — don't spam
    since_reminder = minutes_since(prefs.get("last_reminder_timestamp"))
    if since_reminder < REMINDER_COOLDOWN_MINUTES and level != "strike":
        sys.exit(0)

    # Dedup lock — prevent duplicate reminders from parallel tool calls.
    # Non-blocking: if another hook instance is already emitting, skip silently.
    lock_fd = try_reminder_lock()
    if lock_fd is None:
        sys.exit(0)

    # Re-read prefs after acquiring lock — another instance may have just
    # finished and updated last_reminder_timestamp before we got the lock.
    prefs = read_prefs() or prefs
    since_reminder = minutes_since(prefs.get("last_reminder_timestamp"))
    if since_reminder < REMINDER_COOLDOWN_MINUTES and level != "strike":
        sys.exit(0)

    # Get messages
    content_lines, notif_body = get_persona_messages(prefs, level, elapsed)

    # Update prefs atomically — always reset micro timestamp so a micro
    # reminder doesn't fire right before/after a break or strike reminder.
    def update_prefs(p):
        p["last_reminder_timestamp"] = now_iso()
        p["last_micro_break_timestamp"] = now_iso()
        if level == "strike":
            p["strike_active"] = True
        return p

    read_modify_write(update_prefs)

    # Micro-break — no context enrichment, thin box
    if level == "micro":
        log_event(prefs, "reminder",
            f"Micro-break reminder. {int(elapsed)} min since last break.")
        box = format_box(coach_name, content_lines, "micro")
        notify(coach_name, notif_body)
        emit_allow(center_block(box))

    # Strike — short reason in error callout, full box in systemMessage
    if level == "strike":
        log_event(prefs, "strike",
            f"Strike triggered. {int(elapsed)} min without break.",
            {"strike_active": "false → true"})
        box = format_box(coach_name, content_lines, "strike")
        notify(coach_name, notif_body)
        emit_deny(
            f"On strike — {int(elapsed)} min without a break",
            center_block(box),
        )

    # Break / insist — double box with context enrichment
    log_event(prefs, "reminder",
        f"{'Insistent break' if level == 'insist' else 'Break'} reminder."
        f" {int(elapsed)} min since last break.")
    context = get_context_lines(prefs)
    all_lines = content_lines + context
    box = format_box(coach_name, all_lines, "break")
    centered = center_block(box)
    # Print JSON before notify — if context fetch was slow, we're near the
    # hook timeout. Get the critical output to stdout first.
    sys.stdout.write(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
        },
        "systemMessage": centered,
    }) + "\n")
    sys.stdout.flush()
    if notif_body:
        notify(coach_name, notif_body)
    sys.exit(0)


if __name__ == "__main__":
    main()
