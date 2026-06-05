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


def is_stop_event(hook_input):
    """True iff this invocation is a Stop hook (vs the default PreToolUse).

    Stop fires at the end of every assistant turn — it's the supplemental
    tick source for Pattern A workflows where the user is mostly reading
    long agent output and PreToolUse fires too rarely. Same level-
    determination logic applies; the only differences are output shape
    (no permissionDecision; Stop can't deny) and the tool-specific gates
    don't apply (no tool_name to inspect).
    """
    return hook_input.get("hook_event_name") == "Stop"


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


def emit_stop_message(message):
    """Print Stop hook output with systemMessage and exit.

    Stop's hook schema does NOT accept `hookSpecificOutput.hookEventName:
    "Stop"` — only PreToolUse / UserPromptSubmit / PostToolUse / PostToolBatch
    have hookSpecificOutput entries. Emitting an unknown shape there causes
    Claude Code to dump the full expected-schema as an error on every Stop
    event. We just emit the top-level `systemMessage` field, which IS in
    the schema. No permissionDecision either (Stop can't deny; the turn
    already ended).

    Strike escalation through Stop sets `strike_active=true` in state —
    the next PreToolUse picks up the strike and emits the actual deny.
    """
    print(json.dumps({"systemMessage": message}))
    sys.exit(0)


# ── Schedule-aware defer (Slice 4 of wellness-coverage-audit, 2026-06-05) ──

# Defer-window for "imminent meeting": if a meeting starts within this many
# minutes, defer the real-break nag (no time for a real break anyway). Smaller
# than Petra's MEETING_WINDOW_MIN (30) — Petra paces task suggestions, the
# wellness hook only defers the nag itself.
WELLNESS_MEETING_IMMINENT_MIN = 5


def should_defer_for_meeting():
    """Check the calendar for in-progress or imminent meetings.

    Returns (True, reason_str) if a real-break nag should be deferred;
    (False, '') otherwise. Silent on calendar disabled / fetch failure /
    script missing — treated as 'not deferring' so the wellness hook
    falls through to normal behavior rather than gaming itself off the
    nag path when the calendar layer is unavailable.

    Two checks via forge-calendar.sh:
      - in-meeting       : presence-only; non-empty output → currently in a meeting
      - next-meeting <N> : upcoming-only; non-empty output → meeting starting in <=N min

    Either triggers the defer.
    """
    calendar_sh = os.path.expanduser("~/.claude/scripts/forge-calendar.sh")
    if not os.path.isfile(calendar_sh):
        return False, ""
    try:
        # In-progress check (no parameter)
        out = subprocess.run(
            ["bash", calendar_sh, "in-meeting"],
            capture_output=True, text=True, timeout=10,
        ).stdout.strip()
        if out:
            parts = out.split("|")
            if len(parts) == 2:
                return True, f"in meeting '{parts[0]}' ({parts[1]} min remaining)"
            return True, "in meeting"
        # Imminent check (next WELLNESS_MEETING_IMMINENT_MIN minutes)
        out = subprocess.run(
            ["bash", calendar_sh, "next-meeting", str(WELLNESS_MEETING_IMMINENT_MIN)],
            capture_output=True, text=True, timeout=10,
        ).stdout.strip()
        if out:
            parts = out.split("|")
            if len(parts) == 3:
                return True, f"meeting '{parts[1]}' starting in {parts[2]} min"
            return True, "meeting imminent"
    except (subprocess.TimeoutExpired, subprocess.SubprocessError, OSError):
        # Calendar layer unavailable — treat as "no meeting" so the wellness
        # hook falls through to normal behavior. Don't silently defer; that
        # would game the user out of nags whenever gws auth flakes.
        return False, ""
    return False, ""


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

    # IS_STOP gates the tool-specific logic below. Stop fires at assistant
    # turn-end; there's no tool_input to inspect, no permission to grant/deny.
    # See slice 5 of wellness-coverage-audit (2026-06-05) — Stop is the
    # supplemental tick source for Pattern A workflows where PreToolUse
    # fires too rarely (user is mostly reading long agent output, so the
    # break timer was ticking silently).
    IS_STOP = is_stop_event(hook_input)

    # Always allow the wellness-coach skill through — even during strike.
    # When invoked during an active strike, ONLY lift the strike flag (so the
    # skill body's subsequent state-writes and persona conversation can run).
    # Do NOT auto-credit a break — `last_break_timestamp` and
    # `last_micro_break_timestamp` are left untouched. The skill body's Strike
    # Conversation flow (SKILL.md) decides whether to credit based on the
    # user's actual answer to "did you step away?".
    #
    # Re-strike protection during the conversation: `strike_cleared_at` is
    # set to now, which engages the STRIKE_GRACE_MINUTES (10 min) check
    # downstream so subsequent tool calls don't re-strike while the
    # conversation is in flight, even though `last_break_timestamp` is still
    # stale.
    #
    # Stop events skip this — there's no tool_name to match against.
    if not IS_STOP and is_wellness_coach_skill(hook_input):
        if prefs.get("strike_active"):
            def lift_strike_for_conversation(p):
                now = now_iso()
                p["strike_active"] = False
                p["strike_cleared_at"] = now
                return p
            read_modify_write(lift_strike_for_conversation)
            log_event(prefs, "strike-lifted",
                "Strike flag lifted for wellness-coach conversation; skill body owns the credit decision.",
                {"strike_active": "true → false"})
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

    # Strike already active — block most tool calls.
    # Skip this branch for Stop events: Stop can't deny (the assistant turn
    # already ended) and Stop has no tool_name to match exempt paths against.
    # The next PreToolUse will pick up the strike state and emit the actual
    # block; Stop just stays silent on an existing strike.
    if not IS_STOP and prefs.get("strike_active"):
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
        short_reason = f"On strike — {int(elapsed)} min without a break"

        # Dedup parallel-tool-call spam: N concurrent tool calls each fire
        # this hook, each emitting the full strike box → N identical boxes.
        # Denial must apply to every call (semantic correctness), but only
        # the lock-winner renders the visible box; others deny silently.
        lock_fd = try_reminder_lock()
        if lock_fd is None:
            print(json.dumps({
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": short_reason,
                },
            }))
            sys.exit(2)

        # Hold the lock long enough for sibling processes to start, attempt,
        # and miss. Without this, the winner releases in <5ms — well before
        # the next concurrent process even reaches try_reminder_lock (Python
        # startup ~50ms). Measured inter-process spread across 5 parallel
        # tool calls: ~120ms. 300ms gives margin without harming UX (the
        # user is already blocked during strike, so the delay is invisible).
        time.sleep(0.3)

        lines, _ = get_persona_messages(prefs, "strike", elapsed)
        box = format_box(coach_name, lines, "strike")
        emit_deny(short_reason, center_block(box))

    elapsed = minutes_since(prefs.get("last_break_timestamp"))
    level = determine_level(prefs, elapsed)

    if level is None:
        sys.exit(0)

    # Schedule-aware defer (Slice 4 of wellness-coverage-audit, 2026-06-05).
    # If the user is in a meeting or has one starting imminently, defer
    # real-break nags + strikes — they can't act on them mid-meeting, and a
    # strike fired during a call is pure friction. Micro nags still fire
    # (they're gentle, one-line, and don't escalate). Petra already does
    # this externally for task pacing; the coach now does it natively for nags.
    if level in ("break", "insist", "strike"):
        defer, reason = should_defer_for_meeting()
        if defer:
            # Bump last_reminder_timestamp so subsequent PreToolUse ticks
            # within the meeting hit the standard cooldown and stay silent.
            # When the meeting ends, the nag fires at the next PreToolUse
            # after cooldown elapses — normal cadence resumes.
            def bump_reminder(p):
                p["last_reminder_timestamp"] = now_iso()
                return p
            read_modify_write(bump_reminder)
            log_event(prefs, "deferred-for-meeting",
                f"{level.capitalize()}-level nag deferred — {reason}.",
                {"level": level, "elapsed_min": int(elapsed)})
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
            f"Micro-break reminder. {int(elapsed)} min since last break."
            + (" [via Stop]" if IS_STOP else ""))
        box = format_box(coach_name, content_lines, "micro")
        notify(coach_name, notif_body)
        if IS_STOP:
            emit_stop_message(center_block(box))
        emit_allow(center_block(box))

    # Strike — short reason in error callout, full box in systemMessage.
    # Under Stop, we can't deny (no permission to deny on a turn that's already
    # ending) — set strike_active in state (already done by update_prefs above)
    # and emit a systemMessage. The NEXT PreToolUse will see the strike flag
    # and emit the actual block.
    if level == "strike":
        log_event(prefs, "strike",
            f"Strike triggered. {int(elapsed)} min without break."
            + (" [via Stop — next PreToolUse will enforce]" if IS_STOP else ""),
            {"strike_active": "false → true"})
        box = format_box(coach_name, content_lines, "strike")
        notify(coach_name, notif_body)
        if IS_STOP:
            emit_stop_message(center_block(box))
        emit_deny(
            f"On strike — {int(elapsed)} min without a break",
            center_block(box),
        )

    # Break / insist — double box with context enrichment
    log_event(prefs, "reminder",
        f"{'Insistent break' if level == 'insist' else 'Break'} reminder."
        f" {int(elapsed)} min since last break."
        + (" [via Stop]" if IS_STOP else ""))
    context = get_context_lines(prefs)
    all_lines = content_lines + context
    box = format_box(coach_name, all_lines, "break")
    centered = center_block(box)
    if IS_STOP:
        if notif_body:
            notify(coach_name, notif_body)
        emit_stop_message(centered)
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
        # Credit at NOW, not at auto_break: persisting the wake/boot/screen-on
        # timestamp creates the appearance of off-session monitoring AND can
        # immediately age past the strike threshold on long gaps. `auto_break`
        # remains in scope for the welcome-back recency decision below — that
        # read is in-memory only and never persisted.
        now = now_iso()
        def credit(p):
            p["last_break_timestamp"] = now
            p["last_micro_break_timestamp"] = now
            p["strike_active"] = False
            p["strike_cleared_at"] = None
            p["snooze_count"] = 0
            history = p.get("break_history", []) or []
            history.append({"timestamp": now, "type": "auto-real"})
            p["break_history"] = history
            return p
        read_modify_write(credit)
        prefs["last_break_timestamp"] = now
        prefs["last_micro_break_timestamp"] = now
        prefs["strike_active"] = False
        prefs["snooze_count"] = 0

        changes = {"last_break_timestamp": f"{last_break} → {now}"}
        if old_strike:
            changes["strike_active"] = "true → false"
        if old_snooze:
            changes["snooze_count"] = f"{old_snooze} → 0"
        log_event(prefs, "break-ack",
            f"Detected return from gap; break clock reset at {now}.", changes)
    else:  # micro
        # Same rationale as the real-tier branch above: credit at NOW, not at
        # the wake/screen-on auto_break, to avoid persisting off-session
        # timestamps. The welcome-back recency check below still reads
        # auto_break for its in-memory decision.
        now = now_iso()
        def credit(p):
            p["last_micro_break_timestamp"] = now
            return p
        read_modify_write(credit)
        prefs["last_micro_break_timestamp"] = now

        changes = {"last_micro_break_timestamp": f"{last_micro} → {now}"}
        log_event(prefs, "micro-break-ack",
            f"Detected return from short gap; micro-break clock reset at "
            f"{now}. Real-break timer untouched.", changes)

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
