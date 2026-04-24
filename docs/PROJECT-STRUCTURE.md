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
