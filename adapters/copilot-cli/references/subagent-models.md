# Subagent definitions + model tuning (GitHub Copilot CLI)

GitHub Copilot CLI binding of the per-role tiering half of the model cost posture. The
*why* — cheap orchestrator, premium model as a dispatched scalpel, roles pinned to
the cheapest tier that meets their judgment bar — is the vendor-neutral principle in
[`core/references/model-cost-posture.md`](../../../core/references/model-cost-posture.md).
This file binds it to Copilot CLI: the role-to-tier table, the agent-definition
paths, and the subagent dispatch mechanics.

Background for Forge entry and later role dispatch. Load this file before
dispatching any Forge subagent, including the entry Keeper.

## Subagent definitions

Each Forge role has a GitHub Copilot CLI subagent definition at
`${COPILOT_HOME:-$HOME/.copilot}/agents/forge-{role}.agent.md` (installed from
`adapters/copilot-cli/agents/`). Dispatch via the task tool with
`agent_type: "forge-{role}"`.

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

Role-to-model assignments are **tier-based**. `${COPILOT_HOME:-$HOME/.copilot}/forge.conf`
holds `MODEL_TIER_<ROLE>` keys, each set to `minimal`, `economy`, `standard`,
`premium`, or `inherit` (an absent key also inherits the session model). The
catalog (`${VAULT_PATH}/_shared/model-catalog/catalog.json`) binds tiers to
runtime models. Re-run `/forge-setup-models` to change model mappings.

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

(Read the live values from `${COPILOT_HOME:-$HOME/.copilot}/forge.conf` — the table above is the install-time default, not a substitute for checking.)

## How the binding is enforced

Copilot CLI applies an agent definition's frontmatter `model:` when a dispatch
omits the `model` parameter (verified 2026-10-29: a dispatch with no `model`
ran on the frontmatter model; an explicit `model` overrode it). Forge uses this
to make the tier binding structural:

- `install.sh` and `/forge-setup-models` run `forge-model-catalog.sh render-agents`,
  which resolves each role's `MODEL_TIER_<ROLE>` against the catalog and writes
  the resulting `dispatch_id` as `model:` into
  `${COPILOT_HOME:-$HOME/.copilot}/agents/forge-{role}.agent.md`. A role set to
  `inherit` gets no `model:` line. A role that cannot resolve is left untouched
  and reported.
- Copilot loads agents at start, so a re-render takes effect after a restart.
- **Dispatch rule:** `agent_type: forge-{role}` and **no `model` parameter**.
  Passing one overrides the baked binding.
- **Entry check:** `render-agents --check` compares every installed agent with
  the current mapping. Run it with the literal absolute wrapper path, the
  literal absolute `--snapshot` and `--src-dir` paths, and `--available` set to
  the model IDs from your `task` tool's `model` enum (no shell variables, `~`,
  inline assignments, or compound commands, so saved approvals match):

```bash
"/absolute/copilot/directory/scripts/forge-model-catalog.sh" render-agents --check --snapshot "/absolute/vault/path/_shared/model-catalog/catalog.json" --src-dir "/absolute/copilot/directory/agents" --available "id1,id2,..."
```

| Exit / status | Action |
|---------------|--------|
| `0` / `ok` | Bindings match the current mapping. |
| `5` / `drift` | A remap or tier edit is not rendered yet. Report the roles; on user confirmation re-run without `--check`, then restart Copilot. |
| `2` / `error` | A role's tier has no match or its bound model is stale (`suggestion` is in the row). Do not dispatch that role; repair via `/forge-setup-models`. |

`forge-model-catalog.sh resolve --role {role}` remains available for diagnostics.
The wrapper packages `core/model_catalog/`, which owns neutral tiers and catalog
policy, and pins `copilot-cli`; a foreign `--binding` is rejected. Manual tier
mapping remains user-owned.

## Source of truth per role

Each role's adapter file (`adapters/copilot-cli/agents/forge-{role}.agent.md`
in the repo) defines that role's behavior and tool permissions.

Use subagent dispatch when the operation is **self-contained** (all context can be included in the prompt). Use inline when the operation needs conversation history.

## Conversational model assignment

The user can view or change role models at any time:

- *"show model assignments"* / *"which models are the roles using"* → read `forge.conf`, display the table with current values
- *"set Keeper to minimal"* / *"change Reviewer to premium"* → update the `MODEL_TIER_*` key in `forge.conf`; model-to-tier bindings are changed separately via `/forge-setup-models`

## See also

- `references/model-cost-posture.md` — why the main-loop model and dispatched role tiers have different cost profiles. Actual Copilot model bindings are user-owned; its vendor-neutral principle is `core/references/model-cost-posture.md`
- `references/agent-teams-mode.md` — Pattern A / B / C team-mode dispatch (separate concern from per-role model)
- `adapters/copilot-cli/agents/forge-{role}.agent.md` — per-role adapter definition
