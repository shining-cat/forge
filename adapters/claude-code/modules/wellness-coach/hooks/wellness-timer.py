#!/usr/bin/env python3
"""
PreToolUse hook for wellness-coach Forge module.
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
import json
import os
import subprocess
import sys
import time

# Add plugin directory to path for local modules
PLUGIN_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, PLUGIN_DIR)

from activity_log import log_event
from context import get_context_lines
from formatting import format_box, center_block, try_reminder_lock
from personas import get_persona_messages, get_welcome_back_lines
from preferences import (
    read_prefs, read_modify_write, minutes_since, now_iso,
    read_idle_log, find_last_screen_off_break, get_system_wake_time,
    get_system_boot_time, get_current_screen_state,
    REAL_BREAK_LOCK_THRESHOLD_MINUTES,
)

SCRIPTS_DIR = os.path.join(os.path.dirname(PLUGIN_DIR), "scripts")
REMINDER_COOLDOWN_MINUTES = 5
AUTO_CREDIT_MIN_GAP_SECONDS = 60


# ── Notifications ──────────────────────────────────────────

def notify(title, body):
    """Send macOS notification."""
    script = os.path.join(SCRIPTS_DIR, "notify.sh")
    if os.path.exists(script):
        subprocess.run([script, title, body], capture_output=True, timeout=5)


# ── Hook input helpers ─────────────────────────────────────

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
    return tool_name == "Skill" and tool_input.get("skill") == "wellness-coach"


def is_vault_write(hook_input):
    """Check if the tool call is a Write/Edit targeting the vault.

    Vault writes are automated context preservation (checkpoints, decisions)
    and must not be blocked by strike — blocking them creates a deadlock
    where the system can't save state during enforced breaks.
    """
    tool_name = hook_input.get("tool_name", "")
    tool_input = hook_input.get("tool_input", {})
    file_path = tool_input.get("file_path", "")
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


def is_wellness_state_access(hook_input):
    """Check if the tool call targets wellness-coach state files.

    Covers both `wellness-preferences.json` (user-set config) and
    `wellness-runtime.json` (auto-modified runtime state including
    `strike_active` and timer timestamps). During strike, Claude needs
    read/write access to BOTH so it can credit a break or adjust runtime
    state — blocking either creates a deadlock where the recovery path
    is unreachable from the very state that needs recovering.
    """
    tool_name = hook_input.get("tool_name", "")
    tool_input = hook_input.get("tool_input", {})
    state_files = ("wellness-preferences.json", "wellness-runtime.json")

    if tool_name in ("Read", "Write", "Edit"):
        path = tool_input.get("file_path", "")
        return any(f in path for f in state_files)
    if tool_name == "Bash":
        command = tool_input.get("command", "")
        return any(f in command for f in state_files)
    return False


def is_wellness_script(hook_input):
    """Check if the tool call is a Bash invocation of a wellness-coach script.

    Scripts under `~/.claude/skills/wellness-coach/scripts/` (notably
    `wellness-reset.sh`, `wellness-status.sh`) are recovery / inspection
    helpers. They MUST remain reachable during a strike — otherwise the
    documented recovery path is broken at the exact moment it's needed.
    Match is by directory-prefix substring on the Bash command string.
    """
    tool_name = hook_input.get("tool_name", "")
    if tool_name != "Bash":
        return False
    command = hook_input.get("tool_input", {}).get("command", "")
    return "/.claude/skills/wellness-coach/scripts/" in command


# ── Output helpers ─────────────────────────────────────────

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


# ── Escalation logic ──────────────────────────────────────

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


# ── Main hook logic ───────────────────────────────────────

def main():
    prefs = read_prefs()
    if prefs is None:
        sys.exit(0)

    coach_name = prefs.get("coach_name", "Wellness Coach")
    hook_input = read_hook_input()

    # Always allow the wellness-coach skill through — even during strike.
    if is_wellness_coach_skill(hook_input):
        if prefs.get("strike_active"):
            old_snooze = prefs.get("snooze_count", 0)
            old_last_break = prefs.get("last_break_timestamp")
            def clear_strike(p):
                # Mirror the "real" tier in _credit_auto_break — clearing the
                # strike without resetting last_break_timestamp left the timer
                # poised to re-fire moments later (the cold-start bug).
                now = now_iso()
                p["strike_active"] = False
                p["strike_cleared_at"] = now
                p["snooze_count"] = 0
                p["last_break_timestamp"] = now
                p["last_micro_break_timestamp"] = now
                p["last_reminder_timestamp"] = now
                history = p.get("break_history", []) or []
                history.append({"timestamp": now, "type": "strike-cleared"})
                p["break_history"] = history
                return p
            read_modify_write(clear_strike)
            log_event(prefs, "strike-cleared",
                "Strike cleared via wellness skill invocation.",
                {"strike_active": "true → false",
                 "snooze_count": f"{old_snooze} → 0",
                 "last_break_timestamp": f"{old_last_break} → now"})
        sys.exit(0)

    # Auto-detect breaks from activity monitoring — runs BEFORE strike check
    # so a real break (screen off, system sleep) can clear a strike naturally.
    # Returns (timestamp, tier) where tier is "real" or "micro", or None.
    detected = _detect_auto_break(prefs)

    last_break = prefs.get("last_break_timestamp")
    if detected:
        auto_break, tier = detected
        # Dedup against the right reference: real-tier compares against the
        # real-break timestamp, micro-tier against the micro-break timestamp.
        # Without this, micros re-fire on every hook tick.
        prior = (prefs.get("last_break_timestamp") if tier == "real"
                 else prefs.get("last_micro_break_timestamp"))
        # Rate-limit guard against detector-drift cascades: the activity-monitor
        # path synthesizes a "screen on" sample with fresh time.time() each
        # call, so auto_break creeps forward by seconds per tool call and the
        # auto_break > prior dedup never trips. Anchored on break_history's
        # last entry (only the real-tier credit path writes there), this caps
        # auto-credits to once per AUTO_CREDIT_MIN_GAP_SECONDS regardless of
        # which detector fires. Friction 2026-05-26: 10 credits in 25s at
        # session entry.
        rate_limited = False
        history = prefs.get("break_history") or []
        if history:
            try:
                last_credit_epoch = time.mktime(
                    time.strptime(history[-1]["timestamp"],
                                  "%Y-%m-%dT%H:%M:%S")
                )
                if time.time() - last_credit_epoch < AUTO_CREDIT_MIN_GAP_SECONDS:
                    rate_limited = True
            except (ValueError, KeyError, TypeError):
                pass  # Malformed entry — fall through to existing dedup
        if not rate_limited and (not prior or auto_break > prior):
            _credit_auto_break(prefs, auto_break, last_break, coach_name, tier)
            # Re-read prefs after crediting — strike may have been cleared
            prefs = read_prefs() or prefs

    # Strike already active — block most tool calls
    if prefs.get("strike_active"):
        # Let through:
        #   - vault writes (context preservation must not deadlock)
        #   - wellness state file access (preferences + runtime — recovery path)
        #   - wellness-coach script invocations (wellness-reset.sh etc. — recovery path)
        # Without all three, the documented "skill is reachable during a strike"
        # promise breaks at the runtime layer (see SKILL.md "Strike Conversation").
        if (is_vault_write(hook_input)
                or is_wellness_state_access(hook_input)
                or is_wellness_script(hook_input)):
            sys.exit(0)

        elapsed = minutes_since(prefs.get("last_break_timestamp"))
        lines, _ = get_persona_messages(prefs, "strike", elapsed)
        box = format_box(coach_name, lines, "strike")
        emit_deny(
            f"On strike — {int(elapsed)} min without a break",
            center_block(box),
        )

    elapsed = minutes_since(prefs.get("last_break_timestamp"))
    level = determine_level(prefs, elapsed)

    if level is None:
        sys.exit(0)

    # Grace period after skill-cleared strike
    STRIKE_GRACE_MINUTES = 10
    if level == "strike" and prefs.get("strike_cleared_at"):
        since_cleared = minutes_since(prefs["strike_cleared_at"])
        if since_cleared < STRIKE_GRACE_MINUTES:
            sys.exit(0)

    # Reminder cooldown — don't spam
    since_reminder = minutes_since(prefs.get("last_reminder_timestamp"))
    if since_reminder < REMINDER_COOLDOWN_MINUTES and level != "strike":
        sys.exit(0)

    # Dedup lock — prevent duplicate reminders from parallel tool calls
    lock_fd = try_reminder_lock()
    if lock_fd is None:
        sys.exit(0)

    # Re-read prefs after acquiring lock
    prefs = read_prefs() or prefs
    since_reminder = minutes_since(prefs.get("last_reminder_timestamp"))
    if since_reminder < REMINDER_COOLDOWN_MINUTES and level != "strike":
        sys.exit(0)

    # Get messages
    content_lines, notif_body = get_persona_messages(prefs, level, elapsed)

    # Update prefs atomically
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


def _detect_auto_break(prefs):
    """Check activity monitor, system wake, and boot time for auto-detected breaks.

    Returns (timestamp_iso, tier) where tier is "real" or "micro", or None.

    Activity-monitor samples can yield either tier based on lock duration.
    System wake / boot fallback always returns "real" — sleep/reboot is
    intrinsically a long break (and uses the real-break threshold as its gap
    floor to keep symmetry with the lock-duration tiering).
    """
    last_break = prefs.get("last_break_timestamp")

    # Activity monitor path — granular, can return either tier.
    if prefs.get("activity_monitor_enabled"):
        samples = read_idle_log()
        if samples:
            # If current screen is on but last sample is off, synthesize a transition
            last_sample = max(samples, key=lambda s: s["t"])
            if last_sample["display"] == "off" or last_sample.get("locked"):
                current = get_current_screen_state()
                if current and current["display"] == "on" and not current["locked"]:
                    samples.append({
                        "t": time.time(),
                        "display": "on",
                        "locked": False,
                    })
            micro_t = prefs.get("micro_break_lock_threshold_minutes")
            real_t = prefs.get("real_break_lock_threshold_minutes")
            result = find_last_screen_off_break(samples,
                micro_threshold_minutes=micro_t,
                real_threshold_minutes=real_t)
            if result is not None:
                ts, _duration, tier = result
                return (ts, tier)

    # System wake / boot fallback — always real tier. Gate on the real-break
    # threshold so a 7-min nap doesn't masquerade as a real break.
    # When last_break is None (fresh install / post-reset), any wake/boot
    # event older than the real threshold IS by definition the first signal.
    real_threshold = (prefs.get("real_break_lock_threshold_minutes")
                      or REAL_BREAK_LOCK_THRESHOLD_MINUTES)

    wake_time = get_system_wake_time()
    if wake_time:
        wake_age_min = minutes_since(wake_time)
        if last_break:
            if wake_time > last_break and (minutes_since(last_break) - wake_age_min) >= real_threshold:
                return (wake_time, "real")
        else:
            if wake_age_min >= real_threshold:
                return (wake_time, "real")

    boot_time = get_system_boot_time()
    if boot_time:
        boot_age_min = minutes_since(boot_time)
        if last_break:
            if boot_time > last_break and (minutes_since(last_break) - boot_age_min) >= real_threshold:
                return (boot_time, "real")
        else:
            if boot_age_min >= real_threshold:
                return (boot_time, "real")

    return None


def _credit_auto_break(prefs, auto_break, last_break, coach_name, tier="real"):
    """Credit an auto-detected break and optionally show welcome-back.

    Tier semantics:
      "real"  — reset both timestamps, clear strike, log "auto-real"
      "micro" — reset only last_micro_break_timestamp, keep last_break_timestamp
                and strike intact, log "auto-micro". A short lock isn't a
                substitute for a real break.
    """
    old_strike = prefs.get("strike_active", False)
    old_snooze = prefs.get("snooze_count", 0)
    last_micro = prefs.get("last_micro_break_timestamp")

    if tier == "real":
        def credit(p):
            p["last_break_timestamp"] = auto_break
            p["last_micro_break_timestamp"] = auto_break
            p["strike_active"] = False
            p["strike_cleared_at"] = None
            p["snooze_count"] = 0
            history = p.get("break_history", []) or []
            history.append({"timestamp": auto_break, "type": "auto-real"})
            p["break_history"] = history
            return p
        read_modify_write(credit)
        prefs["last_break_timestamp"] = auto_break
        prefs["last_micro_break_timestamp"] = auto_break
        prefs["strike_active"] = False
        prefs["snooze_count"] = 0

        changes = {"last_break_timestamp": f"{last_break} → {auto_break}"}
        if old_strike:
            changes["strike_active"] = "true → false"
        if old_snooze:
            changes["snooze_count"] = f"{old_snooze} → 0"
        log_event(prefs, "break-ack",
            f"Auto-detected real break. Credited at {auto_break}.", changes)
    else:  # micro
        def credit(p):
            p["last_micro_break_timestamp"] = auto_break
            return p
        read_modify_write(credit)
        prefs["last_micro_break_timestamp"] = auto_break

        changes = {"last_micro_break_timestamp": f"{last_micro} → {auto_break}"}
        log_event(prefs, "micro-break-ack",
            f"Auto-detected micro break (short lock). "
            f"Credited at {auto_break}. Real-break timer untouched.", changes)

    # Welcome-back message if user just returned (within 5 min)
    try:
        break_end_epoch = time.mktime(
            time.strptime(auto_break, "%Y-%m-%dT%H:%M:%S")
        )
        if int((time.time() - break_end_epoch) / 60) <= 5:
            lock_fd = try_reminder_lock()
            if lock_fd is not None:
                persona = prefs.get("persona", "professional")
                wb_lines = get_welcome_back_lines(persona, tier=tier)
                box = format_box(coach_name, wb_lines, "welcome_back")
                log_event(prefs, "welcome-back",
                    f"Welcome-back shown ({tier}) — user returned from "
                    f"auto-detected break.")
                emit_allow(center_block(box))
    except (ValueError, TypeError, OverflowError):
        pass


if __name__ == "__main__":
    main()
