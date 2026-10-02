# Forge — Setup, Customization, and Operations

Install, upgrade, customize, roll back, and extend Forge. For the high-level pitch + daily workflow, see the [README](../README.md). For architecture and components, see [ARCHITECTURE.md](ARCHITECTURE.md). For per-role specifications, see [ROLES.md](ROLES.md). For vault project layout conventions, see [PROJECT-STRUCTURE.md](PROJECT-STRUCTURE.md).

## Requirements

| Requirement | Why |
|-------------|-----|
| [Claude Code](https://claude.ai/code) **or** [GitHub Copilot CLI](https://github.com/github/copilot-cli) | Runtime — choose the matching Forge adapter |
| [superpowers](https://github.com/obra/superpowers-marketplace) | Process discipline — brainstorming, TDD, debugging, plans |
| `jq` | Used by hooks and scripts for JSON processing |
| `python3` | Required for model catalog, task frontmatter updates, and wellness coach hooks |
| `git` | Version control, PR reconciliation |

**Recommended:**
- [Obsidian](https://obsidian.md) — browse the vault with backlinks and graph view
- `terminal-notifier` — macOS notifications when an agent needs approval (`brew install terminal-notifier`)
- [Android CLI](https://developer.android.com/tools/agents/android-cli) — Google's agent-first Android tooling (skills, knowledge base, device management); recommended only if you build for Android
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

## Agent-team panes (`teammateMode`)

Install sets `teammateMode: "auto"` in `~/.claude/settings.json` so Pattern A agent teams open as tmux split-panes (one pane per agent) — only when the key is absent, so a value you set yourself is never overwritten. The first time a session fans out a Pattern A team, Forge surfaces a one-time notice explaining the panes and offering the opt-out.

To change it, edit `~/.claude/settings.json`:

- `"auto"` (install default) — tmux split-panes when inside a tmux session.
- `"tmux"` — force tmux panes.
- `"in-process"` — no panes; teammates run in the background list instead. Pick this if you prefer the panes tucked away.
- `"iterm2"` — iTerm2 panes; requires the `it2` CLI (Shell Integration utilities) on your `PATH`.

## Folder-trust anchor (`FORGE_TRUST_ANCHOR`)

Each agent-team fan-out pane is a *separate* `claude` instance, so each one independently hits Claude Code's folder-trust gate — *"Do you trust the files in this folder?"* — at startup. Left unmanaged, an unattended team spawn stalls on one prompt per pane.

Forge defuses this by launching the tmux session (and every pane it spawns, which inherits the session's working directory) from a single **trust anchor**: the longest common directory prefix of your `VAULT_PATH` and `REPO_ROOTS`. `install.sh` derives it (`forge-context.sh trust-anchor`) and bakes it into `~/.claude/forge.conf` as `FORGE_TRUST_ANCHOR`, re-deriving on every run so it self-heals if your vault or repos move.

**One-time action:** the first time you launch from a fresh shell, Claude Code prompts once to trust that folder. **Accept it.** The acceptance persists to `~/.claude.json`, and every fan-out pane inherits it — panes read nested-repo files by absolute path, so they never *start* inside a nested repo and never re-gate.

If no safe common parent exists (e.g. your vault and repos share only `$HOME`, which is too broad to trust wholesale), install leaves `FORGE_TRUST_ANCHOR` blank and panes may re-prompt. In that case set `teammateMode: "in-process"` (above) — teammates then run concurrently in the background list with no panes and no trust gate.

## Model tiering & cost

Forge treats **Opus as a scalpel, not a substrate.** The single largest cost lever is
the *main interactive loop's* default model — in a measured 30-day profile it was ~94%
of total spend when set to Opus, while subagent fan-out was ~5%. The posture that
follows from that: run a **Sonnet main loop** and reach for Opus deliberately, either
by launching an Opus session for a hard day or by dispatching the Opus-pinned subagent
roles (which carry their own model, independent of the main loop).

**Set the main-loop model** in `~/.claude/settings.json` (this is your daily driver;
Forge does not flip it for you):

```json
{ "model": "sonnet" }
```

Switch the main-loop model only at a **session boundary** — changing it mid-session
invalidates the prompt cache and re-writes the whole resident prefix at the new tier's
price. To get Opus quality from a running Sonnet session without that penalty, dispatch
an Opus-pinned subagent (`architect`, `debugger`, `refiner`, `toolsmith`) — see the
per-role `MODEL_*` keys in `~/.claude/forge.conf` (documented in
`adapters/claude-code/references/subagent-models.md`).

**Measure your own profile before trusting any of these ratios** — they are
environment- and pricing-specific:

```bash
~/.claude/scripts/forge-cost-audit.py                     # per-model cost split, all sessions
~/.claude/scripts/forge-cost-audit.py --days 30           # windowed
~/.claude/scripts/forge-cost-audit.py --cache-composition # gap-bucket cache-writes + 1h-TTL break-even
```

The full rationale, the four moves (Sonnet loop / boundary-only Opus / dispatch heavy
churn / lean resident context), and the ruled-out alternatives (1-hour cache TTL —
measured net loss; mid-session flipping — cache-bust) live in
`adapters/claude-code/references/model-cost-posture.md` — the Claude binding of the
vendor-neutral principle in `core/references/model-cost-posture.md`.

## Model Catalog Setup

Forge's tier system is **vendor-neutral** — it maps available models to abstract tiers, independent of which vendor supplies them. Each organization has different models enabled (Anthropic, OpenAI, Google, etc.), so Forge **cannot ship a pre-baked catalog**. Instead, it guides you through discovering your available models and assigning them to tiers.

### Tier definitions

Four neutral tiers, ordered by cost and reasoning capability:

| Tier | Use case | Examples |
|------|----------|----------|
| **minimal** | Admin tasks with no reasoning needed: Keeper reads/writes, forge startup, web scraping, brain dump truncate | claude-haiku-4, gpt-mini (when available) |
| **economy** | Lightweight reasoning, edge cases, fallback dispatch | gemini-3.8-flash |
| **standard** | Main-loop reasoning, synthesis, review, debugging (default: Sonnet-level) | claude-sonnet-5, gpt-5.4 |
| **premium** | Full-strength reasoning, extended-thinking, scalpel work | claude-opus-5, gpt-5.6-luna, gpt-5.6-terra, gpt-5.6-sol |

The tiers exist because every tier costs more to run than the one below it, so Forge routes work to the cheapest tier that can handle it.

### First-time setup

During the first `/forge` onboarding, supply the model IDs enabled for your active runtime. The installed `/forge-setup-models` skill asks you to **select one model for each tier** (the same model can serve multiple tiers); it makes no inferred choice or automatic discovery. You can rerun the skill whenever you want to change mappings. The canonical catalog is `${VAULT_PATH}/_shared/model-catalog/catalog.json` and holds runtime-specific dispatch bindings; `forge.conf` holds neutral `MODEL_TIER_<ROLE>` policy. Setup tests all four active runtime tiers before publishing. Deferring or making an invalid selection leaves mapping incomplete and preserves the existing catalog and config. Successful mapping also preserves `forge.conf` byte-for-byte: neither role-to-tier keys, legacy model keys, nor the onboarding flag are changed by model setup. After all first-run steps and active-runtime coverage succeed, the separate final onboarding step sets only `ONBOARDING_COMPLETE=true`; deferral or invalid coverage leaves it unchanged.

Confirmed manual mappings remain valid until you change them. System-sourced snapshots still expire after 24 hours; manual remapping accepts a structurally valid expired system catalog, retaining other runtime records with inactive bindings until each runtime is remapped. Resolution requires an exact tier and an active binding for the requested runtime — **there is no cross-tier fallback**. Check coverage with `forge-model-catalog.sh check-coverage --snapshot "${VAULT_PATH}/_shared/model-catalog/catalog.json" --binding claude` (or `--binding copilot-cli`), as appropriate.

## GitHub Copilot CLI adapter

The Copilot adapter is a separate runtime binding. It leaves the Claude adapter
and the agent-neutral role specifications unchanged:

```bash
git clone git@github.com:shining-cat/forge.git
cd forge
./install.sh --runtime copilot --vault-path "$HOME/Vault" --dry-run
./install.sh --runtime copilot --vault-path "$HOME/Vault"
```

The installer targets `${COPILOT_HOME:-$HOME/.copilot}`. It installs Forge
custom agents into `agents/`, skills into `skills/`, runtime scripts into
`scripts/`, hooks into `hooks/`, and creates `forge.conf` only when absent.
Existing Forge-owned files are backed up before replacement; unrelated Copilot
configuration is not rewritten.

Forge entry prefers shorter `$COPILOT_DIR/...` commands when the variable is
inherited and matches the installed directory. Without it, commands fall back
to `${COPILOT_HOME:-$HOME/.copilot}/...`, so no shell configuration is required.
For the shorter form, optionally add this line to `~/.zshrc` or `~/.bashrc`
before starting Copilot CLI (it also respects a custom `COPILOT_HOME`):

```bash
export COPILOT_DIR="${COPILOT_HOME:-$HOME/.copilot}"
```

The installer does not edit shell startup files.

Wellness requires more than copied scripts: the Copilot installer registers
PreToolUse, Stop, and PreCompact hooks, and the eight-question wellness setup
sets `wellness_onboarding_complete: true` only after answers are confirmed.
Until then, the hooks do not send reminders or enforce strikes, even if shared
preferences from another runtime exist. Restart Copilot CLI after installing
to load hooks. If activity-aware monitoring was chosen, its separate
`skills/wellness-coach/scripts/install-monitor.sh` compiles a screen-state
checker and loads a macOS LaunchAgent; the Forge installer alone does not do
this. Check health with `"${COPILOT_HOME:-$HOME/.copilot}/skills/wellness-coach/scripts/wellness-status.sh" --diagnose`.

Calendar checks are opt-in: set `calendar_enabled: true` in the vault's
`_shared/wellness-preferences.json` **and** `CALENDAR_PROVIDER=gws` in the
active runtime's `forge.conf` after confirming Google Calendar access.
Omitting `CALENDAR_PROVIDER` or setting it to an unsupported value (including
`m365`, pending its integration) skips Google calls and reports that the
calendar is unavailable rather than claiming there are no meetings.
Configured `gws` authentication errors are reported; they are not treated as
an empty calendar. To opt out, set `calendar_enabled: false` and remove the
provider setting.

After installation, restart Copilot CLI and run `/skills reload`. Forge roles
are available through `/agent` and the Forge entry skill is available in the
normal Copilot skill picker.

Copilot lifecycle differences are deliberate: session context is injected by
`sessionStart`, prompt headers by `userPromptTransformed`, and the shared
vault/credential guards use Copilot's Claude-compatible `PreToolUse` payload.
Copilot does not expose an equivalent post-compaction event or identical
tmux-pane team substrate, so those behaviors use the documented fallback to
inline subagents.

The runtime-specific implementation is kept in
`adapters/copilot-cli/install.sh`; the root `install.sh` is a neutral dispatcher.
Claude remains the default for backward compatibility, so existing
`./install.sh` commands continue to target Claude Code.

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
4. **Map models** — manually select all four tiers; onboarding stays incomplete if deferred or invalid.
5. **Enter Forge mode** — Petra takes over.

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

## Maintainer mode

For people extending Forge itself — adding skills, tuning hooks, reshaping the vault layout. **You probably don't want this**; most users want the default end-user mode (Forge stays out of its own way).

Two postures, flippable via `MAINTAINER_MODE` in `~/.claude/forge.conf`:

- **End-user (default, `MAINTAINER_MODE=false`)** — Petra stays focused on your project work. Forge-internal machinery (decisions/INDEX maintenance, friction-log curation, BACKLOG triage, vault hygiene) is not surfaced as ambient suggestions. Session-entry recovery skips the open-task and BACKLOG-staleness audits.
- **Maintainer (`MAINTAINER_MODE=true`)** — audit surfaces fire at session entry; Petra proactively suggests vault-hygiene threads; `decisions/` and `INDEX.md` are treated as actionable surfaces rather than noise.

Productivity surfaces (Keeper checkpoint cadence, Refiner correction loop, wellness reminders, PR sync, commit/push nudges, brain-dump prompts, install drift + rollback hints) fire identically in both modes.

What's suppressed in end-user mode:

| Surface | Where it's gated |
|---|---|
| Open-task audit at session entry | `forge-context.sh` (script-level) |
| BACKLOG staleness audit at session entry | `forge-context.sh` (script-level) |
| Petra raising friction-log / decisions / INDEX / BACKLOG / vault-hygiene threads in checkpoint Next-Steps | `forge/SKILL.md` (persona-level) |
| Keeper writing meta-work items into Next-Steps / Open-follow-up sections | `keeper/SKILL.md` (persona-level) |

End-user mode doesn't disable these capabilities — ask for them explicitly or run the audits one-off:

```bash
~/.claude/scripts/forge-context.sh open-task-audit
~/.claude/scripts/forge-context.sh backlog-audit
```

Flip the mode:

```ini
# ~/.claude/forge.conf
MAINTAINER_MODE=true
```

The change takes effect on the next `/forge` invocation.

## Capability catalog

Claude installation includes the stdlib-only resolver at `~/.claude/scripts/forge_capability/` and the wrapper at `~/.claude/scripts/forge-model-catalog.sh`. A missing, malformed, incompatible, or stale system-sourced snapshot fails closed; manual catalogs stay valid until changed; legacy `MODEL_<ROLE>` settings remain readable.

### Capability catalog setup

Claude installs the stdlib-only package at `~/.claude/scripts/forge_capability/`. To publish a manual/runtime catalog without probes, network, or cost data, prepare a JSON record input and run `~/.claude/scripts/forge-model-catalog.sh publish --input catalog.json`. Separately from user model setup, the wrapper exposes `migrate --config ~/.claude/forge.conf`; the existing installer invokes that legacy migration with one `.pre-model-catalog` backup. `/forge-setup-models` never invokes migration or writes `forge.conf`.

### Catalog tests

Run the standard-library catalog suite from the repository root with:

```bash
python3 -m unittest discover -s core -p 'test_*.py'
```

   Before any wellness write or monitor installation, show the full resolved configured vault destination and ask explicit consent; offer an override relative to `_shared`. Default: `${VAULT_PATH}/_shared/wellness-coach`. Use `python3 "${COPILOT_HOME:-$HOME/.copilot}/skills/wellness-coach/hooks/wellness_location.py" directory` to inspect the current location. On consent, stop old Claude/Copilot CLI sessions and both wellness LaunchAgents before copying legacy flat `_shared` data; with old writers inactive, run the resolver `prepare --directory wellness-coach --consent --old-tooling-stopped`. It preserves legacy files, disables onboarding and activity monitoring in the new copy, and publishes the locator atomically last. Do not publish while old processes run; restart sessions/reinstall samplers from updated tooling afterward. If migration fails, leave setup incomplete and report the blocker. Configure the vault `.gitignore` for `**/wellness-runtime.json`, `**/wellness-runtime.tmp`, `**/wellness-idle-log.json`, `**/wellness-idle-sampler.log`, `**/wellness-calendar-cache.json`, `**/wellness-activity-log.md`, `**/wellness-activity-log.md.trimmed`, `**/wellness-preferences.lock`, `**/wellness-preferences.tmp`, `**/wellness-idle-log.*`, and `**/wellness-runtime.json.*`; track the locator and preferences. There is no home-directory fallback.
