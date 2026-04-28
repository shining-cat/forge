# Vault Templates Completeness — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add 4 missing vault templates (`task.md`, `issue.md`, `friction-entry.md`, `project-index.md`) to end frontmatter/structure drift.

**Architecture:** Each template lives in two locations — `core/vault-templates/` in the forge repo (source of truth) and `Vault/_templates/` (immediate-use copy). Style matches the existing 3 templates: minimal scaffold, no inline guidance.

**Tech Stack:** Markdown only. No code, no tests. Verification is visual — file exists, frontmatter matches design, sections match design.

**Design doc:** `~/__DEV/PERSO/forge/.claude/plans/2026-04-28-vault-templates-completeness-design.md`

**Commits:** One bundled commit at the end (per user preference).

---

### Task 1: Add `task.md` template

**Files:**
- Create: `~/__DEV/PERSO/forge/core/vault-templates/task.md`
- Create: `~/__DEV/Vault/_templates/task.md`

**Step 1: Write source in repo**

```markdown
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

**Step 2: Mirror to vault**

```bash
cp ~/__DEV/PERSO/forge/core/vault-templates/task.md ~/__DEV/Vault/_templates/task.md
```

**Step 3: Verify**

```bash
diff ~/__DEV/PERSO/forge/core/vault-templates/task.md ~/__DEV/Vault/_templates/task.md && echo OK
```

Expected: `OK` (no diff output).

---

### Task 2: Add `issue.md` template (stabilisation format)

**Files:**
- Create: `~/__DEV/PERSO/forge/core/vault-templates/issue.md`
- Create: `~/__DEV/Vault/_templates/issue.md`

**Step 1: Write source in repo**

```markdown
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

**Step 2: Mirror to vault**

```bash
cp ~/__DEV/PERSO/forge/core/vault-templates/issue.md ~/__DEV/Vault/_templates/issue.md
```

**Step 3: Verify**

```bash
diff ~/__DEV/PERSO/forge/core/vault-templates/issue.md ~/__DEV/Vault/_templates/issue.md && echo OK
```

Expected: `OK`.

---

### Task 3: Add `friction-entry.md` template (snippet)

**Files:**
- Create: `~/__DEV/PERSO/forge/core/vault-templates/friction-entry.md`
- Create: `~/__DEV/Vault/_templates/friction-entry.md`

**Step 1: Write source in repo**

```markdown
## {{date}} — 

**What happened:** 

**Root cause:** 

**Fix applied:** 

**Rule going forward:** 

**Lesson:** 

---
```

**Step 2: Mirror to vault**

```bash
cp ~/__DEV/PERSO/forge/core/vault-templates/friction-entry.md ~/__DEV/Vault/_templates/friction-entry.md
```

**Step 3: Verify**

```bash
diff ~/__DEV/PERSO/forge/core/vault-templates/friction-entry.md ~/__DEV/Vault/_templates/friction-entry.md && echo OK
```

Expected: `OK`.

---

### Task 4: Add `project-index.md` template

**Files:**
- Create: `~/__DEV/PERSO/forge/core/vault-templates/project-index.md`
- Create: `~/__DEV/Vault/_templates/project-index.md`

**Step 1: Write source in repo**

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

**Step 2: Mirror to vault**

```bash
cp ~/__DEV/PERSO/forge/core/vault-templates/project-index.md ~/__DEV/Vault/_templates/project-index.md
```

**Step 3: Verify**

```bash
diff ~/__DEV/PERSO/forge/core/vault-templates/project-index.md ~/__DEV/Vault/_templates/project-index.md && echo OK
```

Expected: `OK`.

---

### Task 5: Update `docs/PROJECT-STRUCTURE.md` with "Templates available" section

**Files:**
- Modify: `~/__DEV/PERSO/forge/docs/PROJECT-STRUCTURE.md`

**Step 1: Read current state**

Use Read tool on `~/__DEV/PERSO/forge/docs/PROJECT-STRUCTURE.md` to see existing structure and find the right place to insert the new section.

**Step 2: Add "Templates available" section**

Insert a section listing all 7 templates (3 existing + 4 new) with one-line descriptions and "use when" guidance. Suggested content:

```markdown
## Templates available

The vault includes templates for recurring file shapes. Source of truth lives in `core/vault-templates/` in the forge repo; install copies them to `Vault/_templates/` for immediate use in Obsidian.

| Template | Use when |
|----------|----------|
| `checkpoint.md` | Writing the per-project `current-checkpoint.md` (usually via `/forge-checkpoint`, not by hand) |
| `decision.md` | Logging a validated decision (one decision per file, lives in `{project}/decisions/`) |
| `architecture.md` | Documenting an architectural pattern or design doc (lives in `{project}/architecture/`) |
| `task.md` | Bounded work item with a single goal (lives in `{project}/tasks/open/`, moves to `resolved/` when done) |
| `issue.md` | Stabilisation log — multiple sub-issues accumulating around one component over time (per 2026-04-16 stabilisation-task-format decision) |
| `friction-entry.md` | Snippet for appending a new entry to `_shared/friction-log.md` (no frontmatter — it's a section, not a file) |
| `project-index.md` | Starter `INDEX.md` for a new project (about, decisions, tasks links, standing notes) |
```

Insert it after the existing vault-structure description, before any closing sections.

**Step 3: Verify**

Read the modified file and confirm the new section is present and correctly placed.

---

### Task 6: File follow-on task for `install.sh` sync wiring

**Files:**
- Create: `~/__DEV/Vault/PERSO/forge/tasks/open/2026-04-28-install-sh-sync-vault-templates.md`

**Step 1: Write task file using the brand-new `task.md` template (eat our own dogfood)**

```markdown
---
date: 2026-04-28
project: forge
type: task
status: open
tags: [forge, install, vault, templates]
priority: low
---

# Wire `install.sh` to sync vault templates

## What

Add a step to `install.sh` that copies/updates `~/__DEV/Vault/_templates/` from `core/vault-templates/` on every install. Today this sync is manual — the templates were duplicated by hand on 2026-04-28.

## Why

Without install-time sync, new users won't get the templates automatically, and re-installs won't pick up template updates from the repo. Closes the loop opened by the 2026-04-24 vault-templates-completeness task.

## Next

- Read existing `install.sh` to find the right insertion point (likely near where vault structure is scaffolded)
- Add a copy step that mirrors all files in `core/vault-templates/` to `~/__DEV/Vault/_templates/` (preserving existing user customisations? — open question)
- Decide overwrite policy: overwrite always, or only if file unchanged from repo previous version?

## Related

- Parent task: `Vault/PERSO/forge/tasks/open/2026-04-24-vault-templates-completeness.md` (templates added 2026-04-28; this closes the install side)
- Sibling task: `Vault/PERSO/forge/tasks/open/2026-04-24-forge-install-script-completeness.md` (broader install-completeness pass — this could fold into Concern 1's permissions baseline work)
```

**Step 2: Verify**

```bash
ls ~/__DEV/Vault/PERSO/forge/tasks/open/2026-04-28-install-sh-sync-vault-templates.md
```

Expected: file exists.

---

### Task 7: Mark parent task resolved and move it

**Files:**
- Move: `~/__DEV/Vault/PERSO/forge/tasks/open/2026-04-24-vault-templates-completeness.md` → `~/__DEV/Vault/PERSO/forge/tasks/resolved/`

**Step 1: Edit frontmatter — flip `status: open` → `status: resolved`**

Use Edit tool on the file's frontmatter.

**Step 2: Move to resolved/**

```bash
mv ~/__DEV/Vault/PERSO/forge/tasks/open/2026-04-24-vault-templates-completeness.md ~/__DEV/Vault/PERSO/forge/tasks/resolved/
```

**Step 3: Append a brief resolution note inside the file**

Add a `## Resolution (2026-04-28)` section at the bottom noting:
- 4 templates added (`task`, `issue`, `friction-entry`, `project-index`)
- `docs/PROJECT-STRUCTURE.md` updated with templates list
- Install.sh sync wiring deferred to follow-on task `2026-04-28-install-sh-sync-vault-templates.md`

**Step 4: Verify**

```bash
ls ~/__DEV/Vault/PERSO/forge/tasks/resolved/2026-04-24-vault-templates-completeness.md
ls ~/__DEV/Vault/PERSO/forge/tasks/open/2026-04-24-vault-templates-completeness.md 2>&1 | head -1
```

Expected: first command lists the file in resolved/, second errors with "No such file" (good — confirms move).

---

### Task 8: Bundle commit (final step)

**Files:** all changes in `~/__DEV/PERSO/forge/`

**Step 1: Check what's staged**

```bash
git -C ~/__DEV/PERSO/forge status --short
```

Expected: 5 new files in `core/vault-templates/` (4 templates + design doc + plan), 1 modified `docs/PROJECT-STRUCTURE.md`.

**Step 2: Stage repo files**

```bash
git -C ~/__DEV/PERSO/forge add core/vault-templates/task.md core/vault-templates/issue.md core/vault-templates/friction-entry.md core/vault-templates/project-index.md docs/PROJECT-STRUCTURE.md .claude/plans/
```

**Step 3: Commit**

Use a single concise commit message — the forge repo is a public personal repo so multi-line OK if needed.

```bash
git -C ~/__DEV/PERSO/forge commit -m "Add 4 vault templates: task, issue, friction-entry, project-index"
```

**Step 4: Push**

```bash
git -C ~/__DEV/PERSO/forge push
```

Vault changes (templates copy in `Vault/_templates/`, follow-on task file, resolved task move) are not in the repo — vault is a separate filesystem area, not git-tracked. No commit needed for those.

---

## Done criteria

- 4 new templates exist in both `core/vault-templates/` and `Vault/_templates/`, all matching the design doc
- `docs/PROJECT-STRUCTURE.md` has a "Templates available" section listing all 7 templates
- Follow-on task `2026-04-28-install-sh-sync-vault-templates.md` exists in `Vault/PERSO/forge/tasks/open/`
- Parent task `2026-04-24-vault-templates-completeness.md` moved to `Vault/PERSO/forge/tasks/resolved/` with resolution note
- One commit pushed to the forge repo `master`
