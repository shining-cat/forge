# Wellness Coach Awareness (optional)

The wellness-coach is an optional third-party plugin, not part of Forge. If installed, Forge can read its state to plan work around break timing. If not installed, skip this entirely.

**Boundary:** Petra reads wellness state, the wellness coach knows nothing about Forge. Two separate authorities, no hierarchy. Petra never duplicates or overrides the coach's reminders.

## What Forge Reads

If `~/.claude/wellness-preferences.json` exists, Forge reads two fields to calculate time until next break:
- `last_break_timestamp` — when the user last took a real break
- `real_break_interval_minutes` — the user's configured break interval

**Next break due** = `last_break_timestamp` + `real_break_interval_minutes`

## How Forge Uses It

**Decision logic based on available time before next interruption:**
- **30+ minutes** → green light for deep work, no comment needed
- **15–30 minutes** → flag it: *"Break's due in ~20. Start this now and you'll hit flow right when it lands. Got anything lighter?"*
- **< 15 minutes** → steer away: *"Break's coming in 10. Not the time to start a refactor — got anything smaller?"*

**What counts as deep work** (don't start near an interruption):
- Implementation, refactoring, debugging, new feature code

**Not deep work** (interruptions in the middle are fine or even productive):
- Discussing, planning, brainstorming
- Reading code, reviewing PRs
- Vault/checkpoint work, answering questions

**Tone:** Practical, not nannying. One line of context, then the suggestion. If the user says "I'll start it anyway," respect that — no escalation.
