---
date: 2026-04-28
project: forge
type: design
tags: [forge, vault, templates, install, onboarding]
related-task: Vault/PERSO/forge/tasks/open/2026-04-24-vault-templates-completeness.md
---

# Vault Templates Completeness — Design

## Goal

End frontmatter and structure drift in vault files by adding 4 missing recurring-shape templates. Match the existing minimal-scaffold style of the 3 current templates (`checkpoint.md`, `decision.md`, `architecture.md`).

## Motivation

The vault's `_templates/` folder currently has 3 templates from early Forge design. Real-world usage has grown several other recurring file types (tasks, stabilisation issues, friction-log entries, project INDEX files) — all hand-rolled today, all drifting. This is the source of inconsistencies like missing/varying `priority` fields, tags-as-array vs tags-as-string, divergent section headers.

## Scope

Templates only. Install.sh sync wiring deferred to a follow-on task.

## Templates

### 1. `task.md` — bounded work item

```yaml
---
date: {{date}}
project: 
type: task
status: open
tags: []
priority: 
---

# 

## What

## Why

## Next

## Related
```

### 2. `issue.md` — stabilisation log

Follows the 2026-04-16 stabilisation-task-format decision. Distinct from `task.md` because issue files are living logs that accumulate sub-issues over time, not bounded single-goal work.

```yaml
---
date: {{date}}
project: 
type: issue
area: 
status: stabilising
open_issues: 0
resolved_issues: 0
priority: 
---

# Stabilise 

## Context

## Sub-issues

### {{date}} — [open] 

## Resolution criteria
```

### 3. `friction-entry.md` — snippet for `friction-log.md`

Snippet only — no frontmatter. Copy-paste into `_shared/friction-log.md` as a new `## YYYY-MM-DD — Title` entry. Mirrors the recurring shape observed in existing entries.

```markdown
## {{date}} — 

**What happened:** 

**Root cause:** 

**Fix applied:** 

**Rule going forward:** 

**Lesson:** 

---
```

### 4. `project-index.md` — starter INDEX for new projects

```markdown
# {{project}} — Index

## About

- **Repo:** 
- **Remote:** 
- **Git identity:** 
- **Vault path here:** 

## Repo documentation

## Architecture

## Active Decisions

## Tasks

- [tasks/open/](tasks/open/) — open work
- [tasks/resolved/](tasks/resolved/) — completed work, kept for reference

## Standing notes
```

## Locations

Each template is written in two places:

- `~/__DEV/PERSO/forge/core/vault-templates/` — source of truth in repo (alongside the 3 existing source templates)
- `~/__DEV/Vault/_templates/` — immediate-use copy (alongside the 3 existing copies)

## Documentation update

`~/__DEV/PERSO/forge/docs/PROJECT-STRUCTURE.md` — add a "Templates available" section listing all 7 templates with one-line descriptions and "use when" notes.

## Out of scope (follow-on task)

- `install.sh` sync wiring: a step that copies/updates `~/__DEV/Vault/_templates/` from `core/vault-templates/` on every install. To be filed as a new small task entry under `Vault/PERSO/forge/tasks/open/`.

## Style decisions (locked)

- Match existing minimal-scaffold style — frontmatter + section headers only, no inline guidance text. (Rejected: hint comments under each section; YAML field comments.)
- All four templates included in this pass. (Rejected: scope-down to task+issue only.)
