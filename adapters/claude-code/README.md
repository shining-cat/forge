# Forge Claude Code adapter

This adapter maps Forge's agent-neutral roles and skills onto
[Claude Code](https://claude.ai/code) without changing the Copilot CLI adapter
or the role specifications.

## Native surfaces

- `agents/*.md` — Claude Code subagent definitions, dispatched through the
  `Agent` tool and available to agent teams
- `skills/*/SKILL.md` — Claude Code skills discovered from `~/.claude/skills/`
- `hooks/*.sh` — Claude lifecycle hooks registered in `settings.json`
- `scripts/` — Forge runtime, maintenance, and statusline scripts
- `references/` — Claude-specific bindings such as model and subagent posture

The adapter is installed with:

```bash
./install.sh --runtime claude --vault-path "$HOME/Vault"
```

The runtime-specific implementation lives at
`adapters/claude-code/install.sh`; the repository root exposes it through the
neutral `./install.sh --runtime claude` entry point. Running `./install.sh`
without a runtime selector remains equivalent for backward compatibility.

The installer targets `~/.claude/`, preserves user-owned configuration such as
`forge.conf`, and uses the adapter's manifest to manage backups, preview mode,
preserve policies, hook registration, permissions, and symlinked core
references.

## Claude-specific behavior

1. Role definitions use Claude Code frontmatter, including per-role model
   assignments and tool allowlists.
2. Lifecycle behavior is registered through Claude's `settings.json` hooks,
   including prompt-time context injection, pre/post-compaction handling, and
   session cleanup.
3. Agent-team support can use Claude Code's native teammate modes and tmux
   integration when enabled; Forge falls back to sequential dispatch when the
   substrate is unavailable.

The companion
[`agents/README.md`](agents/README.md) documents the Claude subagent file
format and role-definition conventions.
