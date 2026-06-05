# Extended-thinking discipline

Background for the `**Extended-thinking discipline:**` stub in `forge/SKILL.md` Step 7. The short version is one line — *"engage extended thinking on synthesis / root-cause / multi-step decisions; don't engage on routine acks / status reports / mechanical operations"*. Load this file when deciding whether to engage thinking on a non-trivial turn.

## Why discipline matters

Extended thinking emits signature blocks that re-cost the parent context on every subsequent turn — measured at **30–50% of transcript content per long session, ~200K tokens equivalent**. The model decides per turn whether to engage, but explicit self-discipline in routine turns measurably reduces signature accumulation over a day.

## Engage extended thinking ON these operations

- Pattern A synthesis (cross-agent results, judgment under uncertainty)
- Refiner root-cause analysis
- Architect tradeoff weighing for non-trivial design
- Friction triage with > 1 plausible root cause
- Multi-file code review where the bug surface isn't obvious
- Plan authoring for M+ effort work
- Novel scoping passes on open tasks

## Don't engage extended thinking on

- Routine acks / status reports / simple lookups
- Single-tool dispatches where the next step is clear (read this file, run that command)
- Mechanical operations (commit, push, PR open, BACKLOG row update, checkpoint write from accumulated context)
- Re-stating what the user just said
- Reading a file the user pointed at and reporting back
- Vault hygiene tweaks

## Subagent dispatches

When the work is bounded and well-specified, add *"brief response, no extensive analysis"* to the prompt. The subagent's thinking accumulates in its own transcript, but terser subagent output means less material flowing back into the parent.

## Self-check before a heavy turn

Ask *"would I want to re-pay this turn's thinking on every subsequent compaction?"* If yes, think. If no, don't.

## Background

Measurement methodology + the framing for "signature blocks re-cost the context" was captured in `tasks/open/2026-05-22-forge-compaction-frequency-investigation.md` Progress entry 2026-06-03.
