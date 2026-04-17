# Forge

Session orchestration layer for AI-assisted development. Keeps a knowledge vault, runs agent roles, and gives you a consistent workflow across sessions.

## What it does

- **Vault** — persistent knowledge store: decisions, checkpoints, friction log, brain dumps. Plain markdown files, browsable in Obsidian or any editor.
- **Roles** — Keeper (tracks state, logs decisions), Refiner (catches mistakes, proposes fixes), Reviewer (validates plans).
- **Checkpoint system** — automatic breadcrumbs, prompted brain dumps, checkpoint gates on git commit, recovery on session start.
- **Persona** — Petra, the Forge Master. Terse, direct, forge-flavored. A wink, not a performance.
- **Wellness coach** — optional module. Tracks work time, nudges breaks, escalates if ignored. Three persona styles, calendar/weather awareness.

## Architecture

```
forge/
├── core/                          # Agent-agnostic (vault templates, role definitions)
│   ├── references/                # Vocabulary, lifecycle, wellness awareness
│   └── vault-templates/           # Templates for decisions, checkpoints, architecture notes
├── adapters/
│   └── claude-code/               # Claude Code adapter
│       ├── skills/                # Skills (forge, keeper, refiner, plan-reviewer, etc.)
│       ├── hooks/                 # Hook scripts (compaction, approval notifications)
│       ├── scripts/               # Runtime scripts (context tracking, statusline)
│       └── modules/
│           └── wellness-coach/    # Optional wellness module
└── install.sh                     # Installer
```

**Core** defines what Forge is — vault structure, role definitions, reference docs. Agent-agnostic.

**Adapters** wire Forge into a specific AI tool. Currently Claude Code only. Adding support for another tool means writing a new adapter, not changing the core.

## Requirements

| Requirement | Why |
|-------------|-----|
| [Claude Code](https://claude.ai/code) | Runtime — Forge runs as Claude Code skills and hooks |
| [superpowers](https://github.com/obra/superpowers-marketplace) | Process discipline — brainstorming, TDD, debugging, plans |
| `jq` | Used by hooks and scripts for JSON processing |
| `python3` | Used by wellness coach hooks |
| `git` | Version control, PR reconciliation |

**Recommended:**
- [Obsidian](https://obsidian.md) — browse the vault with backlinks and graph view
- `terminal-notifier` — macOS notifications when Claude needs approval (`brew install terminal-notifier`)
- Anthropic official plugins: `code-review`, `commit-commands`, `pr-review-toolkit`

## Install

```bash
git clone git@github.com:shining-cat/forge.git
cd forge
./install.sh
```

The installer will:

1. **Check prerequisites** — Claude Code, jq, git, python3, superpowers
2. **Ask for vault location** — where to store your knowledge vault (default: `~/Vault`)
3. **Copy skills** — 6 core skills + wellness coach files into `~/.claude/skills/`
4. **Install hooks and scripts** — checkpoint tracking, compaction handling, statusline
5. **Configure settings.json** — add hooks and permissions (creates backup first)
6. **Patch paths** — vault location injected into all skills and scripts

Options:
```bash
./install.sh --vault-path ~/my/vault    # Custom vault location
./install.sh -h                         # Help
```

**Updating:** Pull and re-run. The installer is idempotent — it won't duplicate hooks or permissions.

```bash
cd forge
git pull
./install.sh
```

## First session

After install, start Claude Code and type `/forge`. On first run, Forge will:

1. **Offer the wellness coach** — optional break-tracking module. If you decline, it offers to clean up the files.
2. **Verify superpowers** — warns if the plugin isn't installed.
3. **Set up your vault** — creates project directories and starter files.
4. **Enter Forge mode** — Petra takes over.

## How it works

### Session flow

```
/forge                  → Enter Forge mode, load vault, reconcile PRs
  work...               → Keeper tracks decisions, writes checkpoints
  /forge-checkpoint     → Manual checkpoint (also happens automatically)
  correction...         → Refiner identifies root cause, proposes fix
/forge-exit             → Final checkpoint, session summary
```

### Checkpoint tiers

Forge tracks your work automatically at multiple levels:

| Tier | Trigger | What |
|------|---------|------|
| Breadcrumbs | Every tool call | File touched, command run — automatic |
| Brain dump | Every ~10 minutes | Hook prompts you to jot 2-3 lines |
| Checkpoint | Natural pause points | Full state snapshot — goal, progress, next steps |
| Commit gate | `git commit` | Blocks if checkpoint is >15 minutes stale |
| Recovery | Session start | Reconstructs context from all sources |

### Vault structure

```
{vault}/
├── _shared/                    # Cross-project
│   ├── OVERVIEW.md             # All projects at a glance
│   ├── current-checkpoint.md   # Forge-level work state
│   ├── friction-log.md         # What went wrong and why
│   ├── decisions/              # Cross-project decisions
│   └── tasks/                  # Open and resolved tasks
├── _templates/                 # Note templates
├── _meta/                      # Blueprint, changelog
└── {project}/                  # Per-project (or {env}/{project}/)
    ├── INDEX.md                # Active decisions, architecture pointers
    ├── current-checkpoint.md   # Project work state
    ├── braindump.md            # Quick notes between checkpoints
    ├── decisions/              # Project decisions
    └── architecture/           # Architecture notes
```

### Wellness coach (optional)

Tracks work time and nudges you to take breaks. Three persona styles (professional, playful, character), configurable escalation (suggest → escalate → strike), calendar and weather awareness for context-appropriate suggestions.

Offered during first `/forge` session. Can be enabled/disabled anytime.

## Extending

### Adding a project

Create directories in your vault:
```bash
mkdir -p ~/Vault/{project}/decisions ~/Vault/{project}/architecture
```

Then start a Forge session in that project's directory.

### Environment layers

For multi-environment setups (e.g., work + personal), organize the vault with an environment prefix:

```
{vault}/
├── work/
│   └── my-project/
└── personal/
    └── side-project/
```

Forge auto-detects the structure by scanning vault subdirectories.

### Workspace overlays

Organization-specific tooling (private plugins, internal APIs, custom KB integrations) lives outside the Forge repo. Add them via your project's CLAUDE.md or a separate overlay repo.

## License

[GPL-3.0](LICENSE)
