# Forge GitHub Copilot CLI adapter

This adapter maps Forge's agent-neutral roles and skills onto GitHub Copilot CLI
without changing the Claude Code adapter or the role specifications.

## Native surfaces

- `agents/*.agent.md` — user-level Copilot custom agents, selected through `/agent`
- `skills/*/SKILL.md` — user-level Copilot skills, reloaded with `/skills reload`
- `hooks/forge.json` — hook configuration copied to `~/.copilot/hooks/forge.json`
- `scripts/` and `hooks/` — runtime files copied to the corresponding Copilot directories

The adapter is installed with:

```bash
./install.sh --runtime copilot --vault-path "$HOME/Vault"
```

The installer writes only below `${COPILOT_HOME:-$HOME/.copilot}` and preserves
an existing `forge.conf` unless explicitly given a configuration option. If
the Forge development checkout is named differently from the vault project
(for example `FORGE-DEV` beside a separate `FORGE-TOOLING` updater), map it
explicitly when installing from the tooling checkout:

```bash
./install.sh --runtime copilot --vault-path "$HOME/Vault" \
  --forge-project-repo /absolute/path/to/FORGE-DEV
```

This sets `FORGE_PROJECT_REPO` in the local Copilot `forge.conf` only; it does
not rename either clone, copy the development checkout into tooling, or change
`FORGE_REPO` (the tooling/source clone). The path must be an absolute Git
checkout root. Without the option, existing mappings are preserved; other
projects continue to use `REPO_ROOTS`. The runtime-specific implementation lives at
`adapters/copilot-cli/install.sh`; the repository root exposes it through the
neutral `./install.sh --runtime copilot` entry point. It backs up changed
Forge-owned files with a
`.pre-update.<timestamp>` suffix. `--dry-run` prints the planned changes.

Forge entry resolves the installed directory once and submits literal absolute
script paths so saved Copilot CLI command approvals can match. The installer
does not change shell startup files, and custom `COPILOT_HOME` remains supported.

The Copilot adapter intentionally differs from Claude in three places:

1. Agent profiles use Copilot's `.agent.md` format and tool aliases
   (`read`, `search`, `edit`, `execute`, `agent`, `web`).
2. Session and prompt lifecycle behavior is wired through Copilot's
   `sessionStart`, `userPromptTransformed`, `PreToolUse`, `PostToolUse`,
   `Stop`, `PreCompact`, and `SessionEnd` hooks.
3. Copilot has no Claude-style post-compaction event or identical pane-team
   substrate. The adapter runs the pre-compaction guard and documents the
   fallback to inline subagents.
