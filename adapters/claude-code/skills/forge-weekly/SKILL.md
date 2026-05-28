---
name: forge-weekly
description: Use for the weekly wrap-up ceremony. Invoke with /forge-weekly or when the user says "weekly wrap", "close out the week", "weekly retro", "Friday wrap", or similar end-of-week phrasing. Distinct from /forge-exit (daily) — this is the week-rhythm ceremony run by the Quartermaster persona.
---

# Forge Weekly — Quartermaster ceremony

Wraps the week's friction, BACKLOG, and decisions into a closing inventory. Persona switches from Petra (day-work) to Quartermaster (week-work) for the duration of the ceremony — see `references/quartermaster.md` for voice rules.

**Announce:** "**[Quartermaster]** Opening the week-ledger."

## Steps

### 0. Idempotency guard

Run `~/.claude/scripts/forge-context.sh weekly-wrap-due`:

- Output `due` → proceed to Step 1.
- Output `not-due` → the wrap already ran within `FORGE_WEEKLY_WRAP_GAP_DAYS` (default 5). Ask once, in persona:
  > **[Quartermaster]** Ledger was closed less than {N} days ago. Re-open it anyway?

  Yes → proceed to Step 1. No → exit cleanly with *"Nothing to log. Petra has the forge back."* (skip remaining steps and the hand-off line — there's no week-work to close).

### 1. Friction harvest

> **[Quartermaster]** Counting the week's friction.

Run `~/.claude/scripts/forge-context.sh harvest-friction --pretty` to get JSON proposals — each entry has `entry_id`, `date`, `description`, `pattern`, `recurrence`, `proposed_target` (`task` / `decision` / `feedback` / `archive-only`), and `justification`.

Render as a numbered list, grouped by `proposed_target`:

```
=== Friction harvest ({N} unpinned entries since last wrap) ===

Tasks (recurring or recent-unclassified):
  1. 2026-05-26  Lock release before sibling start — file-lock dedup needs hold window
     → task (recurrence=2, structural fix needed)

Archive-only (informational):
  2. 2026-05-19  ...
```

Then **batch fast-path:** *"Apply all proposals as-is? (Y/n, or enter numbers to override)"*

- `Y` → execute each proposal in order. For `task`/`decision`/`feedback` targets, the script's `promote-friction --target <type>` only prints scaffold hints — actual file creation is your work: use the Write tool with the appropriate template from `${VAULT_PATH}/_templates/` (task → `task.md`, decision → `decision.md`, feedback → save to `~/.claude/projects/-Users-<user>/memory/feedback_<slug>.md` per the auto-memory format), then chain to `promote-friction --entry "<id>" --target archive` to clean up the raw entry.
- `n` or number list → per-entry loop, ask for override per item, then proceed.

When the harvest is empty (no unpinned entries in the window), say so plainly and skip to Step 2 — *"No friction this week. Quiet forge."*

### 2. BACKLOG re-rank glance

> **[Quartermaster]** Top of the backlog.

Read the active project's `BACKLOG.md` (path: `${VAULT_PATH}/${ENV}/${PROJECT}/BACKLOG.md`). Show the top 5 rows verbatim, then ask three light questions:

1. **Priority shifts?** — anything that should move up or down based on this week's signal?
2. **Done-but-listed?** — anything still showing as open that actually shipped?
3. **New since Monday?** — anything from this week that should be on the list and isn't?

Apply edits the user confirms. **This is not a full re-grooming** — keep the pass light, 2-3 min max. If the user wants deep BACKLOG work, suggest a separate session.

### 3. Aging-decisions audit

> **[Quartermaster]** Decisions older than 8 weeks.

Read the active project's `INDEX.md` (path: `${VAULT_PATH}/${ENV}/${PROJECT}/INDEX.md`). Locate the decisions section; decisions are stored as inline bullets in the format `- **YYYY-MM-DD — Title:** body`.

Extract dates via regex `^\s*-\s*\*\*(\d{4}-\d{2}-\d{2})`, filter to dates older than 56 days (8 weeks). For each:

> 2026-03-20 — *Single-script-per-skill default* (10 weeks old)
> Still active / archive / revise?

- **Still active** → no change.
- **Archive** → move the bullet to a `## Archived decisions` section in the same INDEX.md (create the section lazily on first archive — append at end of file with a divider).
- **Revise** → mark for follow-up (note in this ceremony's weekly-checkpoint, Step 4) but don't rewrite in-flight.

When zero decisions are old enough, say so and skip — *"All decisions fresh. No audit needed."*

### 4. Week-summary checkpoint

> **[Quartermaster]** Closing the ledger.

Write a new file at `${VAULT_PATH}/${ENV}/${PROJECT}/weekly-checkpoints/YYYY-WNN.md` (create the directory lazily if missing). Use this template:

```markdown
---
date: {today}
iso_week: {YYYY-WNN}
project: {project}
---

# {project} weekly-checkpoint — {YYYY-WNN} ({date range})

## Friction this week
- Harvested: {N} entries
- Promoted to task: {count}
- Promoted to decision: {count}
- Promoted to feedback memory: {count}
- Archived: {count}

## BACKLOG changes
- {bullet per shift, or "no changes"}

## Decisions
- {bullet per archive/revise, or "all fresh"}

## Week vibe
{one line — what the week felt like; can be blank if user prefers}
```

Compute `{YYYY-WNN}` as ISO 8601 week (e.g. `2026-W22`). Compute `{date range}` as Monday–Friday of that ISO week.

### 5. Mark the wrap done

Run `~/.claude/scripts/forge-context.sh mark-weekly-wrap-done`. This updates `${VAULT_PATH}/_shared/forge-runtime.json` with the current timestamp and ISO week, so the next `weekly-wrap-due` check returns `not-due` until the gap elapses.

### 6. Hand-off

Output verbatim:

> **[Quartermaster]** Weekly inventory closed. Petra has the forge back.

If the user is also wrapping the day (Friday late afternoon, prose signals like *"done for the week"* / *"logging off"*), suggest `/forge-exit` as the next step. Do not auto-run it — the ceremony ends with the hand-off line; daily exit is a separate ceremony.

From here forward in the conversation, the `[Quartermaster]` prefix MUST NOT appear again. Petra's voice resumes immediately.

## Notes

- **Persona scope is strict.** The Quartermaster is invoked only by this skill. Outside `/forge-weekly`, Petra owns the voice — including BACKLOG questions, decision questions, friction harvest questions. The persona switch is itself the signal that the user is in week-work; bleeding it elsewhere costs that signal.
- **Vault writes are wellness-strike-exempt** — see wellness-coach SKILL.md "Strike Conversation". No special handling needed.
- **Token cost is per-invocation.** This SKILL + `references/quartermaster.md` only load when `/forge-weekly` runs, not at every `/forge` entry. The forge skill's entry summary only adds a single line (*"Weekly wrap: due"*) when the conditions match.
- **If the ceremony is interrupted** mid-way (e.g. the user steps away mid-harvest), do NOT call `mark-weekly-wrap-done` — leave the ledger open so the next `/forge-weekly` invocation picks up the unharvested entries. Idempotency relies on this discipline.
