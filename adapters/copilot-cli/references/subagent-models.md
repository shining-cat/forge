# Subagent definitions + model tuning (GitHub Copilot CLI)

GitHub Copilot CLI binding of the per-role tiering half of the model cost posture. The
*why* — cheap orchestrator, premium model as a dispatched scalpel, roles pinned to
the cheapest tier that meets their judgment bar — is the vendor-neutral principle in
[`core/references/model-cost-posture.md`](../../../core/references/model-cost-posture.md).
This file binds it to Claude: the role→model table, the agent-definition paths, and
the `Agent()` dispatch mechanics.

Background for the `**Subagent definitions:**`, `**Model tuning:**`, and `**Conversational model assignment:**` stubs in `forge/SKILL.md` Step 7. The short version is one line — *"each Forge role has an agent definition at `$COPILOT_DIR/agents/forge-{role}.md` and a configurable model in `$COPILOT_DIR/forge.conf`"*. Load this file when dispatching a subagent or reasoning about model selection.

## Subagent definitions

Each Forge role has a GitHub Copilot CLI subagent definition at `$COPILOT_DIR/agents/forge-{role}.md` (installed by `install.sh` from `adapters/claude-code/agents/` in the forge repo). Dispatch via `Agent({subagent_type: "forge-{role}", ...})`.

The 8 roles:

- `forge-architect`
- `forge-debugger`
- `forge-impl`
- `forge-keeper`
- `forge-refiner`
- `forge-release`
- `forge-reviewer`
- `forge-toolsmith`

The agent-neutral specs live at `core/roles/{role}.md` in the repo (browseable from the vault via `repo-core/`).

## Model tuning

Role-to-model assignments are **tier-based** (migrated 2026-09-25 — see the model-tiering checkpoint). `$COPILOT_DIR/forge.conf` holds `MODEL_TIER_<ROLE>` keys, each set to one of the 4 tiers (`minimal`, `economy`, `standard`, `premium`, or `inherit`/empty to inherit the session model). The **catalog** (`${VAULT_PATH}/_shared/model-catalog/catalog.json`) is the source of truth for tier→model binding, and is the moving part — re-run `/forge-setup-models` whenever new models become available or the catalog goes stale (records expire after 24h; a resolve against a stale catalog fails loudly with `"snapshot is stale or from the future"` rather than silently falling back).

Defaults (written by `install.sh`), tier assigned per role's judgment bar:

| Key | Default tier | Role | Background |
|-----|---------|------|------------|
| `MODEL_TIER_KEEPER` | `minimal` | Checkpoint writes, index updates | yes |
| `MODEL_TIER_REFINER` | `standard` | Root cause analysis | no |
| `MODEL_TIER_REVIEWER` | `standard` | Structured checklist review | no |
| `MODEL_TIER_IMPL` | `standard` | Implementation | yes |
| `MODEL_TIER_ARCHITECT` | `premium` | Design and tradeoff analysis | no |
| `MODEL_TIER_DEBUGGER` | `standard` | Systematic diagnosis | no |
| `MODEL_TIER_RELEASE` | `standard` | Verification, commits, PRs | no |
| `MODEL_TIER_TOOLSMITH` | `standard` | Skill authoring | no |

(Read the live values from `$COPILOT_DIR/forge.conf` — the table above is the install-time default, not a substitute for checking.)

**Before every Forge subagent dispatch**, resolve the role's tier to an actual `dispatch_id` — don't skip this and let the harness default silently apply (this exact omission caused a real regression: friction 2026-09-28, session-entry Keeper ran on the default model instead of `minimal`/Haiku):

```bash
VAULT_PATH=<vault path> "$COPILOT_DIR/scripts/forge-model-catalog.sh" resolve --role keeper
```

This prints the resolved model's `dispatch_id` for the role's configured tier (looked up via `MODEL_TIER_KEEPER` in `forge.conf` against the active `copilot-cli` bindings in the catalog). Pass that value to the Agent/task tool's `model` parameter: `task({ model: "{dispatch_id}", ... })`. If the tier is `inherit`/empty, or the resolve call errors (e.g. stale catalog), omit the `model` parameter and note the fallback rather than silently proceeding as if the tier were honored.

## Source of truth per role

Each role's adapter file (`adapters/claude-code/agents/forge-{role}.md` in the repo, installed at `$COPILOT_DIR/agents/forge-{role}.md`) is the source of truth for that role's behavior, tools allowlist, and dispatch contract — including subagent-mode caveats and team-mode notes.

Use subagent dispatch when the operation is **self-contained** (all context can be included in the prompt). Use inline when the operation needs conversation history.

## Conversational model assignment

The user can view or change role models at any time:

- *"show model assignments"* / *"which models are the roles using"* → read `forge.conf`, display the table with current values
- *"set Keeper model to haiku"* / *"change Reviewer to opus"* → update the `MODEL_*` key in `forge.conf`, confirm the change

## See also

- `references/model-cost-posture.md` — the main-loop model posture these per-role defaults compose with (Sonnet orchestrates, Opus dispatched as a scalpel; the Opus-pinned roles above are how a cheap main loop still gets Opus quality). Its vendor-neutral principle is `core/references/model-cost-posture.md`
- `references/agent-teams-mode.md` — Pattern A / B / C team-mode dispatch (separate concern from per-role model)
- `adapters/claude-code/agents/forge-{role}.md` — per-role spec (source of truth)
