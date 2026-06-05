---
created: {{date}}
updated: {{date}}
project:
type: task
status: open
tags: []
effort:
impact:
priority:
---

# 

## What / Why

## Design

(added when design phase happens)

## Plan

(added when plan is locked)

## Progress

(running log of slices/commits as work happens; bump frontmatter `updated:` to today's date in the same edit)

## Resolution

(written when complete; describes what shipped, set frontmatter `status: resolved` + `shipped_in: <repo>@<SHA>`)

## Related

---

**Status values:** `open` → `designed` → `plan-ready` → `in-progress` → `resolved`

**Audit-suppressing states (excluded from staleness flags):**
- `status: blocked` — waiting on an external dependency. Pair with a `Progress` entry naming the blocker.
- `status: needs-refinement` — real intent, awaiting design/refinement headspace. Pair with `awaiting:` (free-form) describing what needs to happen before this can move (e.g. `awaiting: forge-cruise-velocity`, `awaiting: kb-owner-handover`).
- `park: true` — intentional plan-prep reference, meant to be read at event-time (next migration, next incident, etc.), not actionable now. Pair with `park_reason:` (free-form) explaining the trigger event.

The `awaiting:` and `park_reason:` fields are informational — the audit doesn't read them; the human reading the task does, when re-evaluating whether the exclusion still applies.

**Naming:** `YYYY-MM-DD-<slug>.md`. Date prefix is the **creation date**, never renamed. Recency lives in the `updated:` frontmatter.

**Sub-tasks:** if this task spawns ship-able sub-pieces, convert it to an umbrella (see `umbrella.md` template) — move this file into a subfolder named after the umbrella's slug, rename to `umbrella.md`, and add sub-task files alongside.
