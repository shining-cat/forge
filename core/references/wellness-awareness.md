# Wellness Coach Awareness (optional)

The wellness-coach is an optional Forge module — bundled with Forge but disabled unless the user opts in during onboarding. If enabled, Forge can read its state to plan work around break timing. If not enabled (or files removed), skip this entirely.

**Boundary:** Petra reads wellness state, the wellness coach knows nothing about Forge. Two separate authorities, no hierarchy. Petra never duplicates or overrides the coach's reminders.

## Cross-window scope: wellness is global by design

Forge's other hooks (braindump prompts, commit gates, checkpoint nags, push/PR nudges) are session-isolated — they only fire in the Claude Code window that ran `/forge`. Wellness is the explicit exception: break time is a *human-state* signal that doesn't depend on which window the user is typing in. If wellness only fired in the Forge window, the user could trivially evade breaks by switching to a sibling terminal.

Concretely: wellness reads `wellness-preferences.json`, NOT the `forge-active` marker. Adapters implementing wellness-coach must preserve this — the coach's reminders fire wherever the user is working, not only in Forge sessions. Adapters MUST surface this design choice to the user during wellness onboarding so the asymmetry isn't a surprise post-install.

## What Forge Reads

If `wellness-preferences.json` exists at `${VAULT_PATH}/_shared/` (or legacy `~/.claude/`), Forge reads two fields to calculate time until next break:
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
