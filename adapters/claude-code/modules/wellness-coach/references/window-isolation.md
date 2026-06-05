# Why wellness fires in every Claude Code window

Background for the `## Why wellness fires in every Claude Code window` mention in `SKILL.md`. The short version is the one inline; this file holds the rationale + the change procedure.

## The rule

Forge's other hooks (braindump prompts, commit gates, checkpoint nags, push/PR nudges) are **session-isolated** — they only fire in the window that ran `/forge`. Wellness is the explicit exception: it fires in **every** Claude Code window.

## Why

Break time is a *human-state* signal. It doesn't depend on which window the user is typing in. If wellness only fired in the Forge window, the user could trivially evade breaks by switching to a sibling terminal — open a second Claude Code window outside Forge, work there for 4h, no nags. The whole education mission collapses.

So wellness reads its own state file (`wellness-preferences.json`), NOT the Forge `forge-active` marker. The hook fires wherever the user happens to be working.

## What this implies

- Multi-terminal state is shared via `${VAULT_PATH}/_shared/wellness-preferences.json` + `wellness-runtime.json`. Always read fresh; never cache.
- A break credited in one terminal resets the timer for ALL terminals.
- A strike in any terminal blocks all terminals.
- Reminders are deduped by `last_reminder_timestamp` across terminals (5-min cooldown) to avoid the same nag showing up in three windows at once.

## How to change this behavior

If you ever want wellness to become session-isolated (e.g. "only nag inside `/forge`"), the change is non-trivial: the hook would need to read the marker, and the cross-terminal cooperative semantics above all need re-evaluation. **File an issue in the Forge repo before changing — it's a load-bearing escapability decision, not a code tweak.**

## See also

- [[onboarding.md]] — the persona / coach-name / interval setup that this file references
- `forge/SKILL.md` step 6 — the broader session-isolation rule wellness opts out of
