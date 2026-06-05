# Plan storage (Forge mode)

Background for the `**Plan storage (Forge mode):**` + `**Claude Code plan mode under Forge.**` stubs in `forge/SKILL.md` Step 7. The short version is one line — *"plan / design / spec content lives as sections inside the relevant vault task file, never as separate sibling files"*. Load this file when writing a plan, entering plan mode, or auditing existing `docs/plans/` content.

## The rule

All canonical plan, design, and spec content MUST live as **sections inside the relevant vault task file**, never as separate `-design.md` / `-plan.md` siblings. Single-doc workflow: plan + design + progress co-located in one task file.

## File-layout cases

- **Single task** (most cases): `{VAULT_PATH}/{ENV}/{PROJECT}/tasks/open/YYYY-MM-DD-<topic>.md` — Design and Plan are sections inside this file (see `_templates/task.md`).
- **Umbrella with ship-able sub-tasks**: `{VAULT_PATH}/{ENV}/{PROJECT}/tasks/open/YYYY-MM-DD-<umbrella-slug>/umbrella.md` + sibling sub-task files (e.g. `A-<sub-task>.md`) inside the same subfolder (see `_templates/umbrella.md`). Discriminator: if a piece could ship on its own, it's a sub-task file; if not, it's a section in the parent.
- **Cross-project / shared work**: `{VAULT_PATH}/_shared/tasks/open/YYYY-MM-DD-<topic>.md` (or umbrella subfolder if multi-ship).

## Naming + recency

Filenames carry the **creation** date and never change. Recency lives in the `updated:` frontmatter field — Keeper bumps it when adding a `## Progress` entry.

## Override of superpowers default

This overrides the default `docs/plans/...` instruction in the superpowers `brainstorming` and `writing-plans` skills. The Forge override is enforced by a PreToolUse hook (`forge-vault-plan-guard.sh`) — Claude cannot write to `docs/plans/` while Forge is active.

## Claude Code plan mode under Forge

Claude Code's plan mode (entered via `Shift+Tab` in the TUI, or via the `EnterPlanMode` tool) pre-allocates a scratch file at `~/.claude/plans/<random-slug>.md`. The Forge hook no longer blocks this path — the harness can pre-allocate freely.

**Petra's responsibility:** plan content's canonical home is always the relevant task file's `## Plan` section, NOT the scratch file.

- For an **in-flight task**, write directly into the task file's `## Plan` section during plan-mode editing (skip the scratch entirely).
- For **brand-new exploration with no existing task**, the scratch file is acceptable as a working draft, but on `ExitPlanMode` create a proper task file under `tasks/open/` and migrate the plan content into its `## Plan` section before any implementation begins.

The scratch file at `~/.claude/plans/` may be left in place — it's not the canonical home and won't be load-bearing.

## See also

- `core/vault-templates/task.md` — single-task template with Design/Plan/Progress sections
- `core/vault-templates/umbrella.md` — umbrella template
- `adapters/claude-code/hooks/forge-vault-plan-guard.sh` — the PreToolUse hook enforcement
