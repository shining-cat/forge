---
name: forge-exit
description: Use when ending a Forge session — writes final checkpoint, summarizes session, and deactivates Forge mode. Invoke with /forge-exit or when the user says "exit Forge", "done for today", or similar.
---

# Forge Exit

Cleanly wraps up a Forge session with a final checkpoint and session summary.

**Announce:** "**[Keeper]** Exiting Forge — writing final checkpoint."

## Steps

### 0. Credit the break (wellness)

`/forge-exit` IS the user stepping away from work — treat it as an explicit "break taken" signal. If wellness-coach is installed, run:

```bash
WELLNESS_RESET="$HOME/.claude/skills/wellness-coach/scripts/wellness-reset.sh"
[ -x "$WELLNESS_RESET" ] && "$WELLNESS_RESET" --full-reset
```

This resets all timer state (`last_break_timestamp`, `last_micro_break_timestamp`, `last_reminder_timestamp`, `strike_cleared_at`) to now, clears any active strike, and appends a `real` break to history.

**Why this MUST run first:** if Pip is already on strike when `/forge-exit` fires, the subsequent Edit/Write tool calls (final checkpoint, marker deactivation) would be blocked. The wellness-coach scripts directory is exempt from strike (see wellness-coach SKILL.md "Strike Conversation" — Bash invocations under `~/.claude/skills/wellness-coach/scripts/` are always reachable), so this call always succeeds — clearing the strike before any other step needs to fire.

If wellness-coach isn't installed, the conditional skips silently — proceed to Step 1.

### 1. Final Checkpoint

Execute the full forge-checkpoint process (gather state, write checkpoint, log decisions).

### 2. Session Summary

Display a compact summary of what happened this session:

```
--- Forge | {PROJECT} — Session Summary ---
Duration: {approximate}
Branch(es): {branches touched}

Completed:
- {item 1}
- {item 2}

Decisions logged:
- {decision 1} (or "none")

Friction events:
- {event 1} (or "none")

Open items:
- {item 1}
- {item 2}

Next session starts with:
- {first next step}
---
```

### 2b. Tomorrow Preview

After the session summary, surface a forward-looking view of tomorrow so the user knows what they're walking into when they next open Forge. Pulls two things:

- **Calendar (if `calendar_enabled: true` in `wellness-preferences.json`):** invoke skill `google-workspace:gws-calendar` for tomorrow's events. List by time. Skip events where `responseStatus: "declined"`. Identify the **first focus block** (a contiguous gap of ≥ 90 min with no meetings, between `working_hours_start` if known and the first meeting).
- **Carry-forward** from this session's "Next session starts with" line and any open tasks marked `next:` in current-checkpoint.

Same honesty rule as the `/forge` entry: never fill with false comfort. If the calendar check is skipped or fails, REPORT THE GAP — don't claim "no meetings tomorrow" without verification.

```
--- Tomorrow ({tomorrow's date}) ---
Calendar:
- 09:00–09:30 Standup
- 11:00–12:00 Sprint planning
- 14:30–15:30 1:1 with {Name}
First focus block: 09:30–11:00 (1h30)

Carry forward:
- {first next step from this session}
- {any open task marked next}
---
```

If calendar is disabled or empty: say so explicitly (*"Calendar disabled."* or *"Tomorrow's calendar empty as of right now."*). Don't omit the section.

### 3. Deactivate

- Clear the forge-active marker: use the **Edit** tool to replace the project name in `${VAULT_PATH}/_shared/forge-active` with a single newline (the file already exists from the `/forge` entry, so Edit is the right tool — Write would require a prior Read in this session). Do NOT use `rm` — it's denied by the global `Bash(rm:*)` rule. The empty-marker convention is recognized by `forge-context.sh` and `forge-compaction.sh` as "Forge deactivated" (same effect as deletion, no permission friction). Resolve `VAULT_PATH` from `~/.claude/forge.conf`.
- Stop using `[Forge | {PROJECT}]` prefix
- Stop proactive Keeper/Refiner behavior
- Session returns to normal mode

## Notes

- If the user just closes the terminal without `/forge-exit`, the proactive Keeper should have already written mid-session checkpoints. The exit is a clean wrap-up, not the only checkpoint.
- If no work was done (e.g., user entered Forge then immediately exits), skip the summary and just confirm exit.
