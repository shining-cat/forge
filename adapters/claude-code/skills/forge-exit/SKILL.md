---
name: forge-exit
description: Use when ending a Forge session — writes final checkpoint, summarizes session, and deactivates Forge mode. Invoke with /forge-exit or when the user says "exit Forge", "done for today", or similar.
---

# Forge Exit

Cleanly wraps up a Forge session with a final checkpoint and session summary.

**Announce:** "**[Keeper]** Exiting Forge — writing final checkpoint."

## Steps

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

### 3. Deactivate

- Remove the forge-active marker: `rm -f ~/.claude/forge-active`
- Stop using `[{PROJECT} | Forge]` prefix
- Stop proactive Keeper/Refiner behavior
- Session returns to normal mode

## Notes

- If the user just closes the terminal without `/forge-exit`, the proactive Keeper should have already written mid-session checkpoints. The exit is a clean wrap-up, not the only checkpoint.
- If no work was done (e.g., user entered Forge then immediately exits), skip the summary and just confirm exit.
