# Wellness Cold-Start Check — internals

Background for the `### 0a. Wellness Cold-Start Check` step in `SKILL.md`. The step itself is one bash invocation; everything below is rationale for *when* and *why* — only matters when debugging the cold-start flow, modifying it, or onboarding a new adapter.

## What the script does

```bash
~/.claude/skills/wellness-coach/scripts/wellness-reset.sh --if-cold-start
```

The script self-gates on `WELLNESS_ENABLED` + `WELLNESS_COLD_START_HOURS` (defaults: disabled, 4h) read from `~/.claude/forge.conf`, and internally invokes `forge-gap-since-last-signal.sh`.

- On a cold start (gap ≥ threshold) it runs a full wellness reset and prints a single line: *"Wellness reset — Forge idle for {Nh}h{Mm}m, break clock zeroed."*
- Otherwise it's silent (exit 0, no stdout).

The SKILL step says "surface stdout verbatim before the step-6 summary" — don't paraphrase, don't omit.

## Why this is step 0a, not step 2.5

If the user has returned after a long gap with an active strike (e.g. ☕ break overdue from the prior session), the strike fires on the FIRST tool call of the new session. Step 0's Read of `~/.claude/forge.conf` is that first call — without 0a, it gets blocked, and the user sees Pip on strike instead of Petra warming the anvil.

`wellness-reset.sh` is on the strike-exemption list (path matches `/.claude/skills/wellness-coach/scripts/`), so it runs cleanly even when a strike is active, and clears the strike in the process. After 0a runs, step 0's Read proceeds normally.

## Why the gap script doesn't need to be exempted

The internal `forge-gap-since-last-signal.sh` call is shell-to-shell (the wellness script invokes it directly), bypassing the Claude tool layer entirely. So the gap script does not need to be on the strike exemption list — it never goes through PreToolUse.

## See also

- [[wellness-awareness.md]] — Petra ↔ wellness coach boundary (Petra reads state; coach knows nothing about Forge)
- [[lifecycle.md]] — full session lifecycle (entry → checkpoint → exit) for which 0a is step 1 in time order
