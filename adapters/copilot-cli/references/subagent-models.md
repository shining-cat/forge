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

**Before every Forge subagent dispatch**, including entry Keeper, resolve the
role's tier with the installed Copilot wrapper. Substitute the actual role
name in `--role`; do not choose a model from the defaults table or rely on
the harness default for a configured tier:

```bash
VAULT_PATH=<vault path> "${COPILOT_HOME:-$HOME/.copilot}/scripts/forge-model-catalog.sh" resolve --role keeper
```

Use the command's JSON `status` **and** exit code:

| Exit / status | Dispatch action |
|---------------|-----------------|
| `0` / `resolved` with a nonempty `dispatch_id` | Pass that exact ID as the task tool's `model` parameter. |
| `1` / `inherit` | Omit `model`; this is intentional session-model inheritance. |
| `2` / `no_match`, `3` / `invalid`, unexpected output/status, or execution error | Do not dispatch that role. Report the role, tier, and resolver error; repair the mapping/config before retrying. |

Do not substitute a model from another runtime or fall back to the harness
default on resolution failure. For entry Keeper, a resolution failure is not
the Keeper-execution fallback: stop entry before dispatch and leave the
pending marker in place until the binding is repaired.

The Copilot wrapper packages and invokes `core/model_catalog/`, which owns neutral tiers and catalog policy. It pins `copilot-cli` for resolve and coverage/onboarding checks; a foreign `--binding` is rejected, and foreign-only tiers return `no_match`. This is a Forge dispatch instruction, not a CLI tool-call interceptor: the orchestrator must pass the selected model. Manual tier mapping remains user-owned.

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
