# Forge Roles — Agent-Neutral Specs

This directory holds the **agent-neutral source of truth** for each Forge role: what it does, when it activates, how it behaves, what it touches in the vault. One file per role.

These specs are intentionally agent-agnostic — they describe the *role*, not its implementation. Each adapter (Claude Code today, others potentially later) carries its own role definition derived from the spec here. The `## Adapters` table in each spec tracks where the adapter implementations live and when they were last synced.

For the high-level role catalog (responsibility, backing dependencies, vault interaction summary), see [../../docs/ROLES.md](../../docs/ROLES.md). The files here go deeper into behavior and triggers.

## File format

```markdown
---
name: {role-name-kebab-case}
type: role
proactive: {true|false}
---

# {Role Name}

## Responsibility
What the role does, in one paragraph. Agent-neutral — no skill names, no tool names, no platform-specific syntax.

## Triggers
When the role activates. Use neutral signals ("user correction", "checkpoint due", "PR opened"), not adapter-specific events ("Stop hook fires", "Skill invocation").

## Behavior
Step-by-step process. Reference vault paths via `${VAULT_PATH}/...`. Reference generic capabilities ("read conversation context", "append to friction log"), not platform-specific tool names.

## Vault interaction
- **Reads:** {paths/areas the role needs to read}
- **Writes:** {paths/areas the role writes}

## Constraints
Red-flag rules — things the role must NOT do, regardless of adapter.

## Adapters

| Agent | File | Last synced |
|---|---|---|
| Claude Code | `adapters/claude-code/agents/forge-{role-name}.md` | YYYY-MM-DD |
```

## Conventions

- **One role per file.** Filename matches the `name` frontmatter field: `refiner.md` for `name: refiner`.
- **No `forge-` prefix on core spec filenames.** The prefix lives in adapter implementations (`forge-refiner.md`) to avoid collision with user-defined roles in the host environment.
- **Update the `Last synced` date** in the Adapters table whenever an adapter implementation is brought in line with a spec change. Mismatched dates are how drift is detected.

## Related

- Adapter implementations: [`../../adapters/claude-code/agents/`](../../adapters/claude-code/agents/) (Claude Code subagent definitions, derived from these specs)
- Architectural design: [`../../docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md)
- Open task: `forge-agent-agnostic-architecture` — this directory is part of that task's deliverable.
