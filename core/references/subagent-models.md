# Subagent definitions + model tuning

Background for the `**Subagent definitions:**`, `**Model tuning:**`, and `**Conversational model assignment:**` stubs in `forge/SKILL.md` Step 7. The short version is one line — *"each Forge role has an agent definition at `~/.claude/agents/forge-{role}.md` and a configurable model in `~/.claude/forge.conf`"*. Load this file when dispatching a subagent or reasoning about model selection.

## Subagent definitions

Each Forge role has a Claude Code subagent definition at `~/.claude/agents/forge-{role}.md` (installed by `install.sh` from `adapters/claude-code/agents/` in the forge repo). Dispatch via `Agent({subagent_type: "forge-{role}", ...})`.

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

Role-to-model assignments are configured in `~/.claude/forge.conf` under `MODEL_*` keys. Read them at session start. Empty value means *"inherit from session model"*.

Defaults (written by `install.sh`):

| Key | Default | Role | Background |
|-----|---------|------|------------|
| `MODEL_KEEPER` | `sonnet` | Checkpoint writes, index updates | yes |
| `MODEL_REFINER` | `opus` | Root cause analysis | no |
| `MODEL_REVIEWER` | `sonnet` | Structured checklist review | no |
| `MODEL_IMPL` | (inherit) | Implementation | yes |
| `MODEL_ARCHITECT` | `opus` | Design and tradeoff analysis | no |
| `MODEL_DEBUGGER` | `opus` | Systematic diagnosis | no |
| `MODEL_RELEASE` | `sonnet` | Verification, commits, PRs | no |
| `MODEL_TOOLSMITH` | `opus` | Skill authoring | no |

When dispatching a subagent for a role, read the model from `forge.conf`:

```bash
grep '^MODEL_KEEPER=' ~/.claude/forge.conf | cut -d= -f2
```

Then pass it to the Agent tool: `Agent({ model: "{value}", ... })`. If the value is empty, omit the `model` parameter (inherits from session).

## Source of truth per role

Each role's adapter file (`adapters/claude-code/agents/forge-{role}.md` in the repo, installed at `~/.claude/agents/forge-{role}.md`) is the source of truth for that role's behavior, tools allowlist, and dispatch contract — including subagent-mode caveats and team-mode notes.

Use subagent dispatch when the operation is **self-contained** (all context can be included in the prompt). Use inline when the operation needs conversation history.

## Conversational model assignment

The user can view or change role models at any time:

- *"show model assignments"* / *"which models are the roles using"* → read `forge.conf`, display the table with current values
- *"set Keeper model to haiku"* / *"change Reviewer to opus"* → update the `MODEL_*` key in `forge.conf`, confirm the change

## See also

- `references/agent-teams-mode.md` — Pattern A / B / C team-mode dispatch (separate concern from per-role model)
- `adapters/claude-code/agents/forge-{role}.md` — per-role spec (source of truth)
