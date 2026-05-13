---
created: {{date}}
updated: {{date}}
project:
type: umbrella
status: open
tags: []
priority:
---

# 

## What / Why

(broad scope of the umbrella; what problem it covers as a whole)

## Design

(shared design context across sub-tasks; tradeoffs that apply to all of them)

## Sub-tasks

Each sub-task is a separate file in this folder. They ship independently, with their own effort/impact/status. Filenames inside the subfolder stay descriptive (e.g. `A-wrap-up-timing.md`, not `A.md`) so wikilinks resolve uniquely across the vault.

| Sub-task | Status | Notes |
|---|---|---|
| [[A-<slug>]] | open | |
| [[B-<slug>]] | open | |

(C / D etc. as needed — letters give a stable handle when discussing in conversation)

## Sequencing

(recommended order of attack across sub-tasks, if dependencies exist)

## Progress

(umbrella-level log: slice-completion landmarks across sub-tasks, scope adjustments, etc. Bump `updated:` on each entry.)

## Resolution

(written when ALL sub-tasks are resolved; or when the umbrella is dissolved/superseded)

## Related

---

**Folder layout:**

```
tasks/open/YYYY-MM-DD-<umbrella-slug>/
├── umbrella.md          (this file)
├── A-<sub-task-1>.md
├── B-<sub-task-2>.md
└── ...
```

**Discriminator for "is it a sub-task file or just a section?"** — if it could ship on its own (independent effort/impact/timing), it's a file. If it only makes sense alongside the parent, it's a section in the parent task file (no umbrella needed).
