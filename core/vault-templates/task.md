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

**Naming:** `YYYY-MM-DD-<slug>.md`. Date prefix is the **creation date**, never renamed. Recency lives in the `updated:` frontmatter.

**Sub-tasks:** if this task spawns ship-able sub-pieces, convert it to an umbrella (see `umbrella.md` template) — move this file into a subfolder named after the umbrella's slug, rename to `umbrella.md`, and add sub-task files alongside.
