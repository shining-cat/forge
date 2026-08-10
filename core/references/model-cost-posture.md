# Model cost posture — Sonnet main loop, Opus as scalpel

Background for the `**Model cost posture:**` stub in `forge/SKILL.md` Step 7. Load this
file when deciding whether to reach for Opus, when the user asks about cost/model
tiering, or when tempted to switch the main-loop model mid-session.

Companion to [`subagent-models.md`](subagent-models.md) — that file covers *which
model each subagent role runs*; this one covers *the main interactive loop's model
and when Opus is worth its price*. They compose: the per-role defaults below are the
mechanism that lets a cheap main loop still get Opus quality on hard work.

Origin: decision `2026-08-10-model-tiering-cost-posture` (in the forge vault). The
ratios below are **environment-specific** — re-measure with `forge-cost-audit.py`
before treating them as ground truth in a new environment.

## The principle

**Opus is the scalpel, not the substrate.** In a measured 30-day profile, Opus as the
default main-loop model was ~94% of total cost; Sonnet subagent fan-out was ~5% and
Haiku ~0.2%. Agent fan-out is already cheap — the spend is the interactive loop's
substrate. So invert the default: **Sonnet orchestrates, Opus is dispatched for
genuinely hard work.**

This is not "Sonnet is good enough" — it's "the orchestrator is judgment-heavy but
not Opus-hard, and the Opus-hard parts are self-contained enough to dispatch." The
main loop makes dispatch decisions, catches mistakes, and follows a large ruleset;
Sonnet holds that well. The mechanical work (checkpoints, backlog edits, path
patching) already lives in scripts and costs $0 — strictly better than any model.
What's left that genuinely needs Opus — deep design, root-cause debugging, skill
authoring — is exactly what the Opus-pinned subagent roles handle.

## The four moves

1. **Default main-loop model = Sonnet.** Set in `~/.claude/settings.json`. This is the
   daily driver. Opus is reserved for a deliberately-Opus session (a hard design/debug
   day) or for dispatched subagents.

2. **Enter Opus at the session boundary, never mid-session.** Switching the main-loop
   model mid-session invalidates the prompt cache — a full re-write of the resident
   prefix at the new tier's write price. For a hard day, *launch* an Opus session. From
   a running Sonnet loop, get Opus quality by dispatching the already-Opus-pinned
   subagents (`architect`, `debugger`, `refiner`, `toolsmith` — see
   [`subagent-models.md`](subagent-models.md)), whose model is independent of the main
   loop and carries no cache-bust.

3. **Dispatch heavy churn to Sonnet Builders.** Multi-file, high read-edit-test work
   runs in a fresh subagent context, keeping the main context lean (cheaper cache-reads
   for the rest of the session). Trivial edits stay inline — and the inline threshold
   *rises* now that the main loop itself is cheap, because the reason to dispatch was
   never just cost, it was context hygiene.

4. **Keep the resident context lean.** `MEMORY.md` and session-entry reads are re-cached
   and re-read every turn — they tax ~87% of tokens (cache-write + cache-read). A diet
   on what stays resident cuts that tax across the whole session.

## Measuring your own profile

The ratios above are specific to one usage pattern and one pricing tier. Re-derive them:

```bash
~/.claude/scripts/forge-cost-audit.py                    # per-model cost split, all sessions
~/.claude/scripts/forge-cost-audit.py --days 30          # windowed
~/.claude/scripts/forge-cost-audit.py --cache-composition # gap-bucket cache-writes + 1h-TTL break-even
```

The `--cache-composition` view is the one that settles the tiering call: it buckets
cache-writes by the idle gap that preceded each, so you can see how much of the spend
is active-work churn (unavoidable) versus idle re-writes (potentially saveable).

## Ruled out (don't re-propose without new measurement)

- **1-hour extended cache TTL** (`ENABLE_PROMPT_CACHING_1H`). Measured **net loss** in
  the reference profile. The 1h TTL raises the write price on *every* cache-write
  (~1.6×) but only saves the idle-re-write bucket. Break-even needs the saveable
  (5min–1h gap) share to exceed ~39.5% of writes; measured share was ~20%, dominated by
  a ~72% ≤60s active-churn bucket that just gets more expensive. Re-run
  `--cache-composition`; only revisit if *your* saveable share clears ~40%.

- **Mid-session model flipping as the tiering mechanism.** Busts the cache (move #2).
  Tier at the session boundary and via subagents instead.
