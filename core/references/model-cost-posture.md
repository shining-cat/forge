# Model cost posture — cheap orchestrator, premium model as a scalpel

Vendor-neutral principle. This file names no specific model and no specific
config — it states *why* Forge tiers its models and *how* the tiering is shaped,
so any adapter can bind it to its own model line-up and controls.

The Claude Code binding of this principle — concrete model names, the settings
and config keys, the measured ratios, the audit commands — lives in
`adapters/claude-code/references/model-cost-posture.md`. When you build a new
adapter, write the sibling binding for that agent; this file is the contract it
implements.

Origin: decision `2026-08-10-model-tiering-cost-posture` (in the forge vault).
Every ratio quoted in an adapter binding is **environment- and pricing-specific**
— re-measure before trusting it in a new environment.

## The principle

**The premium model is a scalpel, not a substrate.** In a hosted agent, the cost
driver is almost always the *main interactive loop's* model — the substrate that
re-caches and re-reads the whole resident context every turn. Subagent fan-out,
by contrast, is cheap: each agent runs a short self-contained context and exits.
Put the expensive model where the whole session pays for it and it dominates the
bill; put it behind a dispatch boundary and it costs a fraction.

So invert the default: **run a cheap model on the orchestrator tier and dispatch
the premium model as a scalpel for the genuinely hard, self-contained work.**

This is not "the cheap model is good enough for everything." It's that the work
splits into three tiers, and only one of them needs the premium model:

- **Orchestrator tier** — makes dispatch decisions, catches mistakes, follows a
  large ruleset, holds the conversation. Judgment-heavy but not premium-hard; a
  mid-tier model holds it well, and it's the substrate every turn pays for.
- **Scalpel tier** — deep design, root-cause debugging, skill authoring. Genuinely
  needs the premium model *and* is self-contained enough to dispatch. This is the
  only tier where the premium model earns its price.
- **$0 script tier** — mechanical work (checkpoints, backlog edits, path patching)
  already lives in scripts and costs nothing — strictly better than any model.

Per-role subagent tiering is the mechanism that makes this work: each role is
pinned to the *cheapest tier that meets its judgment bar*, so a cheap main loop
still gets scalpel-tier quality on the work that needs it, on demand.

## The four moves

1. **Default the orchestrator tier to the cheap model.** This is the daily driver.
   The premium model is reserved for a deliberately-hard session or for dispatched
   subagents — never the default substrate.

2. **Change the orchestrator's tier only at a session boundary, never mid-session.**
   Switching the main-loop model mid-session invalidates the prompt cache — a full
   re-write of the resident prefix at the new tier's write price. For a hard day,
   *launch* a premium session. From a running cheap session, get premium quality by
   dispatching the premium-pinned subagents, whose model is independent of the main
   loop and carries no cache-bust.

3. **Dispatch heavy churn to keep the main context lean.** Multi-file, high
   read-edit-test work runs in a fresh subagent context, keeping the main context
   small and its cache-reads cheap for the rest of the session. Trivial edits stay
   inline — and the inline threshold *rises* once the main loop is cheap, because the
   reason to dispatch was never just per-token cost, it was context hygiene.

4. **Keep the resident context lean.** Whatever stays resident (memory files,
   session-entry reads) is re-cached and re-read every turn, taxing the bulk of
   token spend. A diet on what stays resident cuts that tax across the whole session.

## Measuring before trusting

Every ratio in an adapter binding is specific to one usage pattern and one pricing
tier. Before treating any of them as ground truth, re-derive them with that adapter's
cost-audit tooling. The view that settles the tiering call is a **cache-write
composition** — bucket cache-writes by the idle gap that preceded each, so you can
separate active-work churn (unavoidable) from idle re-writes (potentially saveable).
The tiering decision follows from *your* measured split, not from the reference
numbers.

## Ruled out (don't re-propose without new measurement)

- **A longer cache TTL as a blanket win.** A longer time-to-live raises the write
  price on *every* cache-write but only saves the idle-re-write bucket. It's a net
  loss unless the saveable share is large enough to clear break-even — which, in the
  reference profile, it was not (active sub-minute churn dominated). This is a
  measure-first call, not a default: only revisit if your own saveable share clears
  the break-even threshold.

- **Mid-session model flipping as the tiering mechanism.** Busts the cache (move #2).
  Tier at the session boundary and via subagents instead.
