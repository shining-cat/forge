---
created: {{date}}
updated: {{date}}
project:
type: issue
area:
status: stabilising
tags: []
open_issues: 0
resolved_issues: 0
priority:
---

# Stabilise 

## Context

(what is being stabilised, and why this is a stabilisation pattern rather than a single-ship task or an umbrella with planned sub-tasks)

## Sub-issues

(Reactive log — append new entries as issues are discovered. Mark `[open]` / `[resolved]` inline. Bump frontmatter `updated:` and `open_issues` / `resolved_issues` counts when the list changes.)

### {{date}} — [open] 

## Resolution criteria

(what would let you close this and set `status: resolved` — e.g. "no new sub-issues for 30 days," "open count = 0 for two consecutive sessions," etc.)

---

**Status flow:** `stabilising` → `resolved` (when resolution criteria are met). Auto-archive moves to `tasks/resolved/` on next session entry once `status: resolved`.

**Discriminator vs other shapes:**
- Sub-items are *reactive discoveries* (bugs, gaps, papercuts found during use), not pre-planned features. → use `issue`
- Sub-items are *planned and independently ship-able*. → use `umbrella` (subfolder + sibling files)
- Single ship event, no sub-pieces. → use `task`
