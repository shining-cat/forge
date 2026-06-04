# Forge

Session orchestration layer for AI-assisted development. Keeps a knowledge vault, runs agent roles, and gives you a consistent workflow across sessions.

## Why Forge

Most multi-agent setups quietly turn the human into a router. You open parallel windows because it feels like leverage — but each window is another tab to read, another thread to merge, another mental context to hold. The agents work in parallel; you don't. You sequence yourself across them, paying a context-switch tax on every glance.

That tax is real. Each switch drops one mental model and loads another. The orchestration work — deciding what each agent should do next, reconciling what they produced, keeping the bigger picture coherent — falls on you. The more agents, the more orchestration, the less time spent actually thinking about the problem.

Forge inverts that. One conversation, one point of contact, one orchestrator (Petra) who dispatches subagents internally and reports back. You state intent, review results, make decisions. Routing, dispatch, context-sharing, and reconciliation happen behind the scenes. Your job is to think; Forge's job is to manage the team.

Focus doesn't mean tunnel vision. Forge holds all your projects in one vault, so when a side-thought strikes mid-task — an idea for another project, a question to chase later — you log it in seconds and keep going. You don't lose the spark to the discipline of staying focused, and you don't break focus to chase the spark.

This isn't about being faster than parallel agents. It's about being quieter. If you've found yourself flipping between three terminal panes to figure out what your agents actually did, Forge is for you. The leverage is in keeping your attention on the work, not on the routing.

## What it does

- **Vault** — persistent knowledge store: decisions, checkpoints, friction log, brain dumps. Plain markdown files, browsable in Obsidian or any editor.
- **Roles** — Keeper (tracks state, logs decisions), Refiner (catches mistakes, proposes fixes), Reviewer (validates plans).
- **Checkpoint system** — automatic breadcrumbs, prompted brain dumps, checkpoint gates on git commit, recovery on session start.
- **Persona** — Petra, the Forge Master. Terse, direct, forge-flavored. A wink, not a performance.
- **Friction framework** — converts recurrent friction (permission prompts, prose-discipline failures, role drift) into script-enforced mitigations. Pattern catalog + classifier + gated friction-log writes + audit. See [docs/ARCHITECTURE.md#friction-framework](docs/ARCHITECTURE.md#friction-framework).
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

For the full breakdown of components, dependencies, and how the pieces fit together, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — components, philosophy, where things live, agent roles overview, friction framework
- [docs/ROLES.md](docs/ROLES.md) — per-role specifications (Petra, Keeper, Refiner, Reviewer, Architect, Builder, Debugger, Release Manager, Toolsmith)
- [docs/PROJECT-STRUCTURE.md](docs/PROJECT-STRUCTURE.md) — how to lay out a vault project (INDEX vs checkpoint, on-demand folders, repo-docs symlinks)
- [core/references/script-replacement-patterns.md](core/references/script-replacement-patterns.md) — 5 patterns for converting recurrent friction into script-enforced mitigations
- [core/references/friction-classifier.md](core/references/friction-classifier.md) — decision tree for routing friction shape → pattern slug

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
3. **Copy skills** — 7 core skills + wellness coach files into `~/.claude/skills/`
4. **Install agent definitions** — 8 `forge-*` adapter files into `~/.claude/agents/` (architect, debugger, impl, keeper, refiner, release, reviewer, toolsmith)
5. **Install hooks and scripts** — checkpoint tracking, compaction handling, statusline
6. **Configure settings.json** — add hooks and permissions (creates backup first)
7. **Patch paths** — vault location injected into all skills and scripts

Options:
```bash
./install.sh --vault-path ~/my/vault    # Custom vault location
./install.sh --preview                  # Read-only: what would change (new/modified/removed)
./install.sh --interactive              # Preview + Y/n prompt before applying
./install.sh -h                         # Help
```

**Updating:** Pull and re-run. The installer is idempotent — it won't duplicate hooks or permissions. How a modified file is treated depends on its policy (see **Customization & upgrades** below).

```bash
cd forge
git pull
./install.sh --interactive   # see the diff, confirm, apply  (recommended)
./install.sh                 # apply directly
./install.sh --preview       # read-only — exits 0 if in sync, 1 if drift
```

The installer offers (once, opt-in) to enable a post-merge git hook that prints a one-liner after `git pull` whenever installed files change — a nudge to re-run `./install.sh`. The hook is checked into `.githooks/post-merge`; opting in sets `core.hooksPath` on this clone only. `/forge` entry also surfaces drift via `do_check_install_drift`, but the hook fires the instant a stale install starts.

### Customization & upgrades

Every installed file has one of two upgrade policies, declared in `build_pairs()` inside `install.sh`:

- **overwrite (default)** — code, machinery, persona-bearing prose, agent definitions, SKILL.md files. On upgrade, any local modification is backed up as `<file>.pre-update.<timestamp>` and the upstream version is installed. Files removed from upstream are backed up as `<file>.pre-remove.<timestamp>` before deletion. This is the right policy for anything Forge fully owns.
- **preserve (A2 — Apache-config style)** — files you're expected to tune locally: `statusline.sh`, `forge-tmux.conf`, and the per-skill reference symlinks (`forge/references/*`, `forge-weekly/references/quartermaster.md`, `wellness-coach/references/*`). On upgrade, if your local copy differs from upstream, **install.sh leaves your file untouched** and writes the upstream version as a `<file>.upstream.<timestamp>` sibling so you can diff at leisure. Missing files are still installed; matching files are no-ops. No sibling is written if it would duplicate a previous one (clutter control).

`./install.sh --preview` makes the distinction visible: `~` marks files that would be overwritten, `≈` marks files that would be preserved (sibling written, local kept). Both count as drift for the exit code — divergence is divergence — but `≈` reflects a customization you opted into, not a missed update.

If you want a preserved file restored to upstream wholesale, `rm` it and re-run `./install.sh` — the missing-file branch installs from upstream cleanly.

### Rollback

Every `install.sh` run leaves backup artifacts under `~/.claude/`:

- `<file>.pre-update.<ts>` — overwrite-policy file backed up before being replaced
- `<file>.pre-remove.<ts>` — overwrite-policy file backed up before being deleted
- `<file>.upstream.<ts>` — preserve-policy sibling holding upstream content (your local file is untouched)

The `rollback-install` subcommand of `forge-context.sh` operates on them:

```bash
~/.claude/scripts/forge-context.sh rollback-install              # default: list

# Inventory all artifacts grouped by target
~/.claude/scripts/forge-context.sh rollback-install list

# Restore a .pre-update / .pre-remove backup over its target
# (diff is shown, prompt confirms; current target is saved as .pre-rollback.<ts> first)
~/.claude/scripts/forge-context.sh rollback-install restore <path>

# For a preserve-policy file: replace the local copy with the .upstream sibling
# (the A2-style "I changed my mind, take upstream" path)
~/.claude/scripts/forge-context.sh rollback-install accept-upstream <path>

# Prune old backups — keep the N most recent per (kind, target), drop the rest
~/.claude/scripts/forge-context.sh rollback-install clean --dry-run        # default: keep last 3
~/.claude/scripts/forge-context.sh rollback-install clean --keep-last 5
~/.claude/scripts/forge-context.sh rollback-install clean --older-than 7 --yes
```

`/forge` entry surfaces a "Rollback available" hint alongside the install-drift block when artifacts exist — your cue that there's something to revert if the latest update misbehaves.

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
  /forge-weekly         → Friday wrap: harvest friction, audit decisions, log week (Quartermaster persona)
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
├── _shared/                    # Shared / cross-cutting work
│   ├── friction-log.md         # What went wrong and why
│   ├── wind-down-phrases.json  # Personal end-of-day vocabulary (learned)
│   ├── decisions/              # Decisions that span projects
│   └── tasks/                  # Cross-cutting tasks (the `_shared` folder
│                               #   behaves like another project for tasks)
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

### Prose wind-down trigger

When you signal end-of-day in prose — *"done for today"*, *"calling it"*, *"logging off"*, etc. — instead of typing `/forge-exit`, Forge:

1. Silently resets your wellness break clock (you're winding down either way).
2. Asks once whether to run the full exit, so the session ends cleanly with a final checkpoint and the marker torn down. Saying *"yes"* runs `/forge-exit`; *"no, sticking around"* leaves the session warm.

**Personal phrase list.** Forge ships with a seed list of canonical wind-down phrases. When you confirm a novel phrase ("I'm winding down"), Forge **learns it** — appends it to a personal list at `${VAULT_PATH}/_shared/wind-down-phrases.json` so it counts as canonical next time (no educational tip needed). You can view or prune the list directly:

```bash
~/.claude/scripts/forge-context.sh wind-down-list   # show learned phrases
$EDITOR ${VAULT_PATH}/_shared/wind-down-phrases.json   # edit / prune
```

The list is vault-resident — it travels with your vault across machines.

**Why offer exit, not checkpoint?** Closing the forge cleanly at end of day is a wellness practice — same family as the wellness coach. An offered checkpoint that you don't follow with an exit leaves the marker stale and hooks firing into a dead session; the exit flow writes the final checkpoint *and* tears down session state in one move.

### Maintainer mode

Two postures, picked during onboarding (and flippable anytime via `MAINTAINER_MODE` in `~/.claude/forge.conf`):

- **End-user mode (default, `MAINTAINER_MODE=false`)** — Petra stays focused on your project work. Forge's own machinery (decisions/INDEX maintenance, friction-log curation, BACKLOG triage, vault hygiene threads) doesn't get surfaced as ambient suggestions. Session-entry recovery skips the open-task and BACKLOG-staleness audits to keep the summary tight.
- **Maintainer mode (`MAINTAINER_MODE=true`)** — for people extending Forge itself (adding skills, tuning hooks, reshaping the vault layout). Audit surfaces fire at every session entry, Petra proactively suggests vault-hygiene threads (friction-log promotions, decision archival, stale-task triage), and `decisions/` / `INDEX.md` get treated as actionable surfaces rather than noise.

What stays identical in both modes:

- Project work, the Keeper's checkpoint cadence, the Refiner's correction loop, wellness reminders, PR sync, commit/push nudges, brain-dump prompts, install drift + rollback hints. These are productivity surfaces, not Forge-internal machinery, so they fire the same way.

What changes in user mode (suppressed by default):

| Surface | Where it's gated |
|---|---|
| Open-task audit (`Possibly-shipped tasks (>Nd, not in checkpoint)`) at session entry | `forge-context.sh` (script-level) |
| BACKLOG staleness audit at session entry | `forge-context.sh` (script-level) |
| Petra proactively raising friction-log / decisions / INDEX / BACKLOG / vault-hygiene threads in checkpoint Next-Steps | `forge/SKILL.md` (persona-level) |
| Keeper writing meta-work items into Next-Steps / Open-follow-up sections | `keeper/SKILL.md` (persona-level) |

End-user mode doesn't disable these capabilities — you can still ask for any of them explicitly, or run the audits one-off:

```bash
~/.claude/scripts/forge-context.sh open-task-audit
~/.claude/scripts/forge-context.sh backlog-audit
```

Flip the mode by editing `~/.claude/forge.conf`:

```ini
MAINTAINER_MODE=true   # or false
```

The change takes effect on the next `/forge` invocation.

## Extending

### Adding a project

Create directories in your vault:
```bash
mkdir -p "$VAULT_PATH/{project}/decisions" "$VAULT_PATH/{project}/architecture"
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

## Developing on Forge

If you're contributing to the forge repo itself (vs just using forge), run the one-time dev setup after cloning:

```bash
./scripts/setup-dev.sh
```

This installs git hooks that lint each commit — currently a `no-hardcoded-paths` check that prevents maintainer paths (`__DEV`, `/Users/...`) and brand identifiers from leaking into shipped code. Idempotent; re-run safe.

## License

[GPL-3.0](LICENSE)
