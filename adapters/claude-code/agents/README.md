# Forge Roles — Claude Code Subagent Definitions

This directory holds **Claude Code-specific implementations** of each Forge role, derived from the agent-neutral specs in [`../../../core/roles/`](../../../core/roles/). Each file is a [Claude Code subagent definition](https://code.claude.com/docs/en/sub-agents) that:

1. Can be invoked via the `Agent` tool: `Agent({subagent_type: "forge-{role}", prompt: "..."})`.
2. Can be referenced as an [agent-team](https://code.claude.com/docs/en/agent-teams) teammate type: `"Spawn a teammate using the forge-{role} agent type to..."`.

The same file serves both dispatch modes.

## File format

Standard Claude Code subagent definition format:

```markdown
---
name: forge-{role-name}
description: {discovery prose — when Claude should use this role}
tools: {comma-separated tool allowlist}
model: {opus|sonnet|haiku}
---

# {Role Name}

## Responsibility
Translated from core spec.

## Behavior
Step-by-step, with concrete Claude Code tool names (Edit, Read, Bash, etc.) and concrete file paths.

## Constraints
Red-flag rules.
```

## Conventions

- **`forge-` prefix is mandatory** on the `name` frontmatter and the filename. Protects against collision with user-defined roles in the host environment.
- **`tools` allowlist is intentional.** Each role gets only the tools it needs. Team-coordination tools (`SendMessage`, task management) are always available regardless.
- **`model` matches `forge.conf` `MODEL_*` keys.** Source of truth for per-role model assignment is `~/.claude/forge.conf`; this field locks in the default for non-Forge sessions and team-mode dispatch.
- **Body must be self-contained.** When run as a teammate, this file's body is appended to the teammate's system prompt — the teammate doesn't load the core spec at runtime. Translate canonically; don't reference the core spec as if it were live.
- **Caveat (per Anthropic docs):** `skills` and `mcpServers` frontmatter fields are NOT applied when this definition runs as a teammate. Only `tools`, `model`, and body apply. If the role depends on a skill, document that dependency in the body so a teammate prompt can include the relevant skill invocation.

## Sync with core specs

When this file is updated to match a change in `../../../core/roles/{role}.md`, update the `Last synced` date in that core spec's `## Adapters` table. Mismatched dates flag drift.

## Installation

`install.sh` (claude-code adapter stage) copies these files to `~/.claude/agents/`. Once installed, the host Claude Code discovers them automatically — no per-role registration needed.

## Related

- Agent-neutral specs: [`../../../core/roles/`](../../../core/roles/) (source of truth)
- Anthropic agent-teams docs: https://code.claude.com/docs/en/agent-teams
- Anthropic subagent docs: https://code.claude.com/docs/en/sub-agents
