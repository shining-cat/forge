---
type: reference
---

# Project Structure in the Vault

Every project tracked by Forge gets a folder in the vault, optionally under an environment prefix: `{ENV}/{project}/` for multi-environment setups, or just `{project}/` if you only have one environment.

## Principles

1. **INDEX is a table of contents, not a container.** It points to things wherever they live — vault files, repo docs, external URLs. No duplication.
2. **INDEX = slow-changing identity. Checkpoint = ephemeral state.** If it survives across sessions, it belongs in the index. If it changes every session, it belongs in the checkpoint.
3. **Folders are created on demand, not pre-scaffolded.** Don't create `architecture/` or `decisions/` until something needs to go there.
4. **Repo docs stay in the repo.** The index references them by path. Claude reads them when needed. They're not duplicated into the vault.

## Minimal project folder

```
{project}/
├── INDEX.md
└── current-checkpoint.md
```

These two files are always present. Everything else is created when first needed.

## INDEX.md — project identity

Slow-changing reference. Updated when the project itself evolves, not every session.

| Section | Content | When to update |
|---------|---------|----------------|
| About | One-liner, repo path, team/owner | Rarely — project rename, team change |
| Project docs | Paths to docs in the repo (not duplicated) | When docs are added/removed in the repo |
| Architecture | Inline notes or links to `architecture/` files | When architecture decisions are made |
| Decisions | Inline notes or links to `decisions/` files | When project-specific decisions are validated |

Lightweight items go inline. Items complex enough to warrant their own file get a folder (`architecture/`, `decisions/`).

## current-checkpoint.md — session state

Ephemeral snapshot. Overwritten at every natural pause point. Old versions exist in git history.

| Section | Content |
|---------|---------|
| Current goal | What we're working on right now |
| Active branch | Current git branch |
| In review | Open PRs awaiting review |
| Next steps | Immediate action items |
| Blockers | Anything preventing progress |
| Session notes | Ephemeral context that won't survive to INDEX |

**Does NOT contain:** completed PR history, team info, project description, architecture — those belong in INDEX.

## Repo docs (symlink)

Project documentation that lives in the repo is not duplicated into the vault. Instead, a symlink brings it in:

```
{project}/repo-docs → /path/to/repo/docs/
```

This makes repo docs browsable in Obsidian and clickable from INDEX.md links. The INDEX references them as `[ARCHITECTURE](repo-docs/ARCHITECTURE.md)`.

Create the symlinks when adding a project to the vault:
```bash
# Docs folder
ln -s /path/to/repo/docs /path/to/vault/{project}/repo-docs

# Individual root-level files (README, etc.)
ln -s /path/to/repo/README.md /path/to/vault/{project}/repo-README.md
```

Use the `repo-` prefix for all symlinked content to make it visually distinct from vault-native files.

## Optional folders (created on demand)

| Folder | Purpose | When to create |
|--------|---------|----------------|
| `architecture/` | Architecture notes too complex for INDEX inline | First architecture decision that needs detail |
| `decisions/` | Project-specific decisions with rationale | First decision that needs its own file |
| `tasks/open/` | Open project-level tasks | First task logged |
| `tasks/resolved/` | Completed project-level tasks | First task resolved |

## Task file shapes (single-doc workflow)

Forge uses a **single-doc workflow** for task files: one growing file per task, with sections (What/Why → Design → Plan → Progress → Resolution) added as the work evolves. No more separate `-design.md` / `-plan.md` siblings — design and plan live as sections inside the parent task file.

Three coexisting shapes, each fitting a different work pattern:

| Shape | Use when | Sub-items live as | Title prefix | Done status |
|-------|----------|-------------------|--------------|-------------|
| **`task.md`** | One ship event, linear evolution | sections (Design, Plan, Progress) | "Do X" | `resolved` |
| **`issue.md`** | Reactive stabilisation; sub-items are small fixes discovered over time | inline `## Sub-issues` section | "Stabilise X" | `resolved` (interim: `stabilising`) |
| **`umbrella.md`** | Pre-planned breakdown; sub-pieces ship independently with their own effort/impact/timing | separate sub-task files in a subfolder named after the umbrella's slug | "X umbrella" | `resolved` (resolves when all sub-tasks done) |

### Discriminator: which shape do I use?

> *Is the sub-piece independently ship-able as a feature?* → **umbrella** (sub-task as a file in the subfolder)
> *Is it a small reactive fix in a stabilisation pattern?* → **issue** (sub-issue as a section)
> *Is there one ship event with linear evolution?* → **task** (single doc with section sequence)

### Filename convention

- Filenames carry the **creation date** as a `YYYY-MM-DD-<slug>.md` prefix.
- **Filenames are never renamed** — recency lives in the `updated:` frontmatter field, not the filename.
- BACKLOG sorts rows within each cluster by `updated:` (most recent first); the Keeper bumps `updated:` when adding a `## Progress` entry to a task.
- Wikilinks resolve by basename across the vault — keep filenames unique vault-wide. Inside an umbrella subfolder, sub-task files stay descriptive (e.g. `A-wrap-up-timing.md`, not `A.md`) for the same reason.

### Umbrella subfolder layout

```
tasks/open/YYYY-MM-DD-<umbrella-slug>/
├── umbrella.md           ← the umbrella file itself (this is what the BACKLOG row links to)
├── A-<sub-task-1>.md     ← independently ship-able sub-task
├── B-<sub-task-2>.md
└── ...
```

The umbrella gets ONE BACKLOG row. Sub-tasks are listed inside `umbrella.md`, not as separate BACKLOG rows.

### Status vocabulary (standardised across all three shapes)

`open` → `designed` → `plan-ready` → `in-progress` → `resolved`

Issue uses `stabilising` as the interim state (instead of `open`/`designed`/etc.) and `resolved` as the final state — same final state as task and umbrella.

### Auto-archive (Keeper duty)

When the Keeper sees `status: resolved` in a task's frontmatter, the next session entry auto-archives it:

- Standalone `task.md` or `issue.md` → moved to `tasks/resolved/` (flat).
- `umbrella.md` (with `status: resolved`) → the whole containing subfolder is moved to `tasks/resolved/` atomically.
- Sub-task inside an umbrella subfolder → stays in place; archived only when the umbrella itself resolves.

The session-entry recovery output emits an `--- Auto-archive ---` summary listing what was moved. The Keeper does NOT auto-edit the BACKLOG — the summary signals which rows to remove on the next BACKLOG curation.

### Vault sync (commit + push action)

When the vault accumulates uncommitted work, invoke `/forge-vault-sync` (or run `bash ~/.claude/scripts/forge-context.sh vault-sync` directly) to get a categorized view. The output groups dirty files by top-level directory (`_shared/`, `_templates/`, `{ENV}/{PROJECT}/`) and suggests one commit per group, with a sensible default message based on the directory name and file shape.

**Two modes:**

- **Report (default):** read-only. Useful for orientation: "what's dirty in the vault and what would I commit?"
- **Interactive (`--commit` flag):** walks each group, asks Y/N to commit, runs the commits, then asks whether to push. Skipped groups stay unstaged for you to handle later. Run from a real terminal — the prompts read from the tty.

```bash
# Report
bash ~/.claude/scripts/forge-context.sh vault-sync

# Interactive commit + push
bash ~/.claude/scripts/forge-context.sh vault-sync --commit
```

**Refusal cases:** vault not under git, vault clean, or pre-staged files already exist (commit or unstage them first — vault-sync owns the staging area only when it's empty).

**Companion to auto-archive:** auto-archive handles the OPEN side (resolved tasks moving out of `tasks/open/`); vault-sync handles the CLOSE side (committing the resulting vault state).

## Templates available

The vault includes templates for recurring file shapes. Source of truth lives in `core/vault-templates/` in the forge repo; install copies them to `Vault/_templates/` for immediate use in Obsidian.

| Template | Use when |
|----------|----------|
| `checkpoint.md` | Writing the per-project `current-checkpoint.md` (usually via `/forge-checkpoint`, not by hand) |
| `decision.md` | Logging a validated decision (one decision per file, lives in `{project}/decisions/`) |
| `architecture.md` | Documenting an architectural pattern or design doc (lives in `{project}/architecture/`) |
| `task.md` | Bounded work item with a single ship event (single-doc shape — sections evolve over the task's life). Lives in `{project}/tasks/open/`. |
| `issue.md` | Reactive stabilisation log — multiple sub-issues accumulating around one component over time (per 2026-04-16 stabilisation-task-format decision). |
| `umbrella.md` | Pre-planned breakdown into independently ship-able sub-tasks. Lives in `{project}/tasks/open/<umbrella-slug>/umbrella.md` with sibling sub-task files in the same folder. |
| `friction-entry.md` | Snippet for appending a new entry to `_shared/friction-log.md` (no frontmatter — it's a section, not a file) |
| `project-index.md` | Starter `INDEX.md` for a new project (about, decisions, tasks links, standing notes) |
