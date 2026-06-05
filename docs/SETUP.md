# Forge — Setup, Customization, and Operations

Install, upgrade, customize, roll back, and extend Forge. For the high-level pitch + daily workflow, see the [README](../README.md). For architecture and components, see [ARCHITECTURE.md](ARCHITECTURE.md). For per-role specifications, see [ROLES.md](ROLES.md). For vault project layout conventions, see [PROJECT-STRUCTURE.md](PROJECT-STRUCTURE.md).

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
3. **Copy skills** — 11 core skills (`forge`, `forge-checkpoint`, `forge-exit`, `forge-weekly`, `forge-audit`, `forge-audit-permissions`, `forge-vault-sync`, `keeper`, `refiner`, `plan-reviewer`, `promote-from-review`) + wellness coach module into `~/.claude/skills/`
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

## Customization & upgrades

Every installed file has one of two upgrade policies, declared in `build_pairs()` inside `install.sh`:

- **overwrite (default)** — code, machinery, persona-bearing prose, agent definitions, SKILL.md files. On upgrade, any local modification is backed up as `<file>.pre-update.<timestamp>` and the upstream version is installed. Files removed from upstream are backed up as `<file>.pre-remove.<timestamp>` before deletion. This is the right policy for anything Forge fully owns.
- **preserve (A2 — Apache-config style)** — files you're expected to tune locally: `statusline.sh`, `forge-tmux.conf`, and the per-skill reference symlinks (`forge/references/*`, `forge-weekly/references/quartermaster.md`, `wellness-coach/references/*`). On upgrade, if your local copy differs from upstream, **install.sh leaves your file untouched** and writes the upstream version as a `<file>.upstream.<timestamp>` sibling so you can diff at leisure. Missing files are still installed; matching files are no-ops. No sibling is written if it would duplicate a previous one (clutter control).

`./install.sh --preview` makes the distinction visible: `~` marks files that would be overwritten, `≈` marks files that would be preserved (sibling written, local kept). Both count as drift for the exit code — divergence is divergence — but `≈` reflects a customization you opted into, not a missed update.

If you want a preserved file restored to upstream wholesale, `rm` it and re-run `./install.sh` — the missing-file branch installs from upstream cleanly.

## Rollback

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

## Maintainer mode

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
