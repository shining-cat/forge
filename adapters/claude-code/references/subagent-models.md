# Subagent definitions + model tuning (Claude Code)

Claude Code binding of the per-role tiering half of the model cost posture. The
*why* — cheap orchestrator, premium model as a dispatched scalpel, roles pinned to
the cheapest tier that meets their judgment bar — is the vendor-neutral principle in
[`core/references/model-cost-posture.md`](../../../core/references/model-cost-posture.md).
This file binds it to Claude: the role→model table, the agent-definition paths, and
the `Agent()` dispatch mechanics.

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

## Review evidence protocol

Only Reviewer issues review verdicts; Petra may relay an actual result with its verified source reference. This applies to every role, including Release and Keeper, and to sequential or parallel dispatch.

1. **Name the target.** Supply the review stage (plan/code), artifact, and exact revision/scope in the Reviewer dispatch. A plan section version or code commit/diff snapshot must identify what approval would cover.
2. **Wait for the actual result.** Dispatch a separate `forge-reviewer` Agent and wait for completion. An invocation, running agent, failed dispatch, producer summary, or self-reported task identifier is not a review result. Preserve FAIL/ESCALATE; absent or failed reviews are unreviewed.
3. **Verify provenance and scope.** Cross-check the result against the actual Reviewer dispatch metadata and tool-result/conversation history, not an identifier written by a model. Match stage, artifact, and revision/scope; missing, stale, or mismatched evidence cannot open the gate. Changed reviewed content needs re-review; unrelated edits outside the reviewed scope do not invalidate it. Plan approval is not code approval.
4. **Handle producer claims.** Flag unsupported Reviewer/PASS claims from non-reviewer outputs; do not silently accept them or rewrite them into success. Keep the affected gate closed and dispatch Reviewer if no matching evidence exists. Without verified evidence, report exactly `Review status: not reviewed (Petra to dispatch Reviewer)`. Producers with verified evidence cite only its reference and scope, not their own verdict.
5. **Persist verified evidence.** Give Keeper the actual source reference (Agent result or transcript/tool-result location), stage, artifact/revision, and exact Reviewer verdict to record in the task. Keeper must not upgrade a producer claim into a review. A missing vault log alone is not a missing review: recover and verify the actual result, then have Keeper repair persistence. If evidence cannot be recovered, obtain a real review. Report persistence failures without fabricating a result; do not treat them as loss of an otherwise verified review.
6. **Record actual incidents.** When an unsupported claim occurs, follow the existing Refiner/maintainer-mode friction policy; do not manufacture a friction event for a missing log or merely mentioning review rules.

These are instruction-level dispatcher checks. The static contract regression checks the shipped guidance, not live agent compliance; there is no runtime hook validating review-result provenance.

## Conversational model assignment

The user can view or change role models at any time:

- *"show model assignments"* / *"which models are the roles using"* → read `forge.conf`, display the table with current values
- *"set Keeper model to haiku"* / *"change Reviewer to opus"* → update the `MODEL_*` key in `forge.conf`, confirm the change

## See also

- `references/model-cost-posture.md` — the main-loop model posture these per-role defaults compose with (Sonnet orchestrates, Opus dispatched as a scalpel; the Opus-pinned roles above are how a cheap main loop still gets Opus quality). Its vendor-neutral principle is `core/references/model-cost-posture.md`
- `references/agent-teams-mode.md` — Pattern A / B / C team-mode dispatch (separate concern from per-role model)
- `adapters/claude-code/agents/forge-{role}.md` — per-role spec (source of truth)

## Capability catalog

`core/model_catalog/` owns neutral tiers, schema, validation, and catalog policy. The Claude adapter packages and invokes it through `forge-model-catalog.sh`, which pins `claude` for resolve and coverage/onboarding checks. A foreign `--binding` is rejected; foreign-only tiers return `no_match`, not another runtime's dispatch ID. Users choose model-to-tier bindings manually, and the adapter dispatches the selected Claude model. Empty or unavailable catalogs fail closed and preserve legacy `MODEL_*` behavior.
