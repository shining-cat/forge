# Forge — Architecture

What Forge IS — its components, how they fit together, and the principles that drive it. For the high-level pitch and daily workflow, see the [README](../README.md). For install / customization / rollback, see [SETUP.md](SETUP.md). For per-role details, see [ROLES.md](ROLES.md). For vault project layout conventions, see [PROJECT-STRUCTURE.md](PROJECT-STRUCTURE.md).

## Philosophy

1. **Visibility** — All accumulated knowledge is browsable in Obsidian
2. **Reliability** — Decisions persist across and within conversations
3. **Self-improvement** — Friction events feed back as permanent improvements

The human is the architect and decision-maker. Agents execute, challenge during design, and maintain knowledge.

## Components

The forge is assembled from Claude Code building blocks, in two layers: **skills** (what Claude invokes — most user-facing) and **hooks + scripts + config** (what the runtime layer wires up around them).

### Skills (11 + wellness module)

| Skill | What it does |
|-------|-------------|
| `forge` | Entry point — loads vault, syncs own + reviewed PRs, activates Petra and session rules |
| `forge-checkpoint` | Mid-session state save |
| `forge-exit` | End-of-session wrap-up |
| `forge-weekly` | Friday wrap ceremony — friction harvest, BACKLOG triage, draft promotion (Quartermaster persona) |
| `forge-audit` | User-invocable scan for MUST/Never/always-style prose in skills/scripts (recurrence-aware) |
| `forge-audit-permissions` | Surfaces anti-patterns in `settings.json` permission rules |
| `forge-vault-sync` | Commit + push the vault when drift accumulates (categorized commits) |
| `keeper` | Decision logging, checkpoints, scope monitoring, INDEX maintenance, auto-archive |
| `refiner` | Friction detection, root cause analysis, classification, friction-log writes |
| `plan-reviewer` | Checklist-based plan validation |
| `promote-from-review` | Walks the user through extracting durable patterns from merged review docs into `patterns/`, then deletes the review doc |
| `wellness-coach` | Forge module (skill + hooks + scripts) — break reminders, escalation, strike enforcement (optional, opt-in) |

### Hooks, scripts, and config

| Component | Type | What it does |
|-----------|------|-------------|
| `wellness-timer.py` | Hook (PreToolUse + Stop) | Runtime break timer — injects reminders, blocks tools on strike. Stop tick covers workflows where PreToolUse fires too rarely (user reading long agent output). Schedule-aware defer for in-progress / imminent meetings. |
| `wellness-precompact.py` | Hook (PreCompact) | Break suggestion during compaction |
| `idle-sampler.py` | Daemon (launchd, 60s) | Samples screen state when activity monitor is enabled. Marker-gated: no-ops when Forge isn't active. |
| `approval-notifier.sh` | Hook (PreToolUse) | Notification on tool approval prompts |
| `forge-compaction.sh` | Hook (PreCompact + PostCompact) | Warns if checkpoint stale (PreCompact), reminds to reload Forge after (PostCompact) |
| `forge-vault-plan-guard.sh` | Hook (PreToolUse on Write/Edit) | Blocks plan content writes outside the vault (e.g. `docs/plans/`) — enforces the single-doc workflow |
| `forge-vault-write-guard.sh` | Hook (PreToolUse on Write/Edit) | Denies raw vault writes from the main session — forces Tier 1 script / Tier 2 subagent. Exempts subagents via `agent_id` |
| `forge-credential-guard.sh` | Hook (PreToolUse on Bash) | Asks before a content-printing verb inspects a credential-bearing file — backstop against secret leaks into the transcript. Always-on (not marker-gated) |
| `forge-session-end.sh` | Hook (SessionEnd) | Clears the `forge-active` marker on session close |
| `inject-current-time.sh` | Hook (UserPromptSubmit) | Injects authoritative `[Current local time: ...]` + the expected block-header prefix into every prompt |
| `forge-context.sh` | Script (multi-subcommand) | The runtime workhorse — `recover`, `gate`, `post-tool`, `stop`, `vault-sync`, `review-sync`, `substrate-check`, `framework-budget`, `next-meeting`, `wrap-up-state`, `append-friction`, `resolve-task`, `render-backlog-cell`, `rollback-install`, etc. ~30 subcommands |
| `forge-calendar.sh` | Script | gws-calendar wrapper — `entry-fetch`, `delta-check`, `next-meeting`, `in-meeting`. Underpins Petra meeting-awareness + wellness schedule-aware defer |
| `forge-classify-friction.sh` | Script | Keyword router: friction shape → pattern slug + action-ref. Powers the Refiner's `append-friction` handoff |
| `forge-cost-snapshot.sh` | Script | Reads transcript metrics, emits `suggest_compact: true/false` for proactive `/compact` discipline |
| `forge-gap-since-last-signal.sh` | Script | Unified gap detection across checkpoints / marker / braindumps / vault git. Underpins cold-start logic |
| `forge-permission-lint.sh` | Script | Fails install when `settings.json` permissions match known anti-patterns; also surfaced via `/forge-audit-permissions` |
| `forge-shell-init.sh` | Shell wrapper | Auto-wraps interactive `claude` in tmux for agent-team substrate |
| `statusline.sh` | Script (statusline) | Status bar showing session state, drift, next break, next meeting |
| `settings.json` | Config | Hook wiring, permissions, plugin enablement |
| `forge-tmux.conf` | Config | tmux config consumed by `forge-shell-init.sh` (mouse-on for scroll-buffer correctness) |

### Where components live

| Location | Content |
|----------|---------|
| `~/.claude/skills/{name}/SKILL.md` | 11 skill definitions: `forge`, `forge-checkpoint`, `forge-exit`, `forge-weekly`, `forge-audit`, `forge-audit-permissions`, `forge-vault-sync`, `keeper`, `refiner`, `plan-reviewer`, `promote-from-review` (+ wellness-coach when opted in) |
| `~/.claude/skills/forge/references/` | Forge skill references — 18 files, loaded on-demand from main `SKILL.md` stubs. Lifecycle / vocabulary / wellness-awareness / wellness-cold-start / agent-teams-mode / maintainer-mode / extended-thinking-discipline / proactive-compact / plan-storage / subagent-models / marker-takeover / pr-sync / wrap-up-state / prose-wind-down / script-replacement-patterns / friction-classifier / credential-discipline / forge-permissions. Source-of-truth list: `core/references/` in the repo |
| `~/.claude/skills/wellness-coach/references/` | Wellness references — 6 files: `onboarding`, `conflict-resolution`, `window-isolation`, `personas`, `auto-detected-tiers`, `strike-conversation`. Loaded on-demand from wellness `SKILL.md` stubs |
| `~/.claude/agents/` | Subagent adapter definitions (forge-architect, forge-debugger, forge-impl, forge-keeper, forge-refiner, forge-release, forge-reviewer, forge-toolsmith) — dispatched via the Agent tool with `subagent_type: "forge-{role}"` |
| `~/.claude/hooks/` | Hook scripts (`approval-notifier.sh`, `forge-compaction.sh`, `forge-vault-plan-guard.sh`, `forge-vault-write-guard.sh`, `forge-credential-guard.sh`, `forge-session-end.sh`, `inject-current-time.sh`) |
| `~/.claude/scripts/` | Maintenance + runtime scripts (`forge-context.sh`, `forge-calendar.sh`, `forge-classify-friction.sh`, `forge-cost-snapshot.sh`, `forge-gap-since-last-signal.sh`, `forge-permission-lint.sh`). `forge-permission-lint.sh` runs at install end (fail-closed) and via the `/forge-audit-permissions` skill |
| `~/.claude/statusline.sh` | Claude Code statusline component — deploys to `~/.claude/` root (not `scripts/`) to match `settings.json` `statusLine.command` path |
| `~/.claude/skills/wellness-coach/` | Wellness coach module (skill, hooks, scripts) — installed by Forge when the user opts in during onboarding |
| `~/.claude/settings.json` | Hook configuration, permissions, plugin enablement |
| `${VAULT_PATH}/_shared/wellness-preferences.json` | Wellness coach runtime state — vault location to avoid `~/.claude/` sensitive-zone permission prompts |
| `~/.claude/forge.conf` | Per-install configuration (vault path, repo path, model assignments) |
| `~/.claude/forge-shell-init.sh` | Shell wrapper sourced by the user's `~/.zshrc` / `~/.bashrc`. Wraps interactive `claude` invocations in tmux so Pattern A agent teams can spawn as panes without user pre-setup. Auto-bypasses when not interactive, already inside tmux, or tmux is missing. Manual bypass: `FORGE_NO_TMUX_WRAP=1` |
| `~/.claude/forge-tmux.conf` | tmux config consumed by `forge-shell-init.sh` via `tmux -f`. Sources the user's own `~/.tmux.conf` first (if any) then forces `set -g mouse on` so wheel/trackpad events scroll tmux's own buffer — without it, xterm-family terminals translate wheel events to arrow keys on the alt-screen, which Claude Code receives as junk input |
| `${VAULT_PATH}/_shared/forge-active` | Session marker — JSON `{session_id, project, started_at, tmux_pane}` (active, owned by that session); empty (deactivated); `__pending__` (launching). Hooks gate on `session_id` so they only fire in the window that ran `/forge`. Lives in the vault to avoid `~/.claude/` sensitive-zone permission prompts |
| `{vault}/` | Knowledge vault (see [Vault Structure](#vault-structure)) |

### External dependencies

Skills reference capabilities from these marketplaces:

| Marketplace | Skills used by forge roles |
|-------------|--------------------------|
| `superpowers-marketplace` | brainstorming, writing-plans, systematic-debugging, writing-skills, finishing-a-development-branch, verification-before-completion, executing-plans, test-driven-development, subagent-driven-development, dispatching-parallel-agents, requesting-code-review, receiving-code-review, using-git-worktrees |
| `claude-plugins-official` | code-review (code-simplifier, code-reviewer), commit-commands (commit, commit-push-pr), pr-review-toolkit (review-pr, silent-failure-hunter, type-design-analyzer, pr-test-analyzer, comment-analyzer) |
| Optional / org-specific | google-workspace, jira, developer-documentation (private marketplaces — not bundled with Forge) |

## Vault Structure

```
{vault}/
├── _shared/                ← shared / cross-cutting runtime work
│   ├── friction-log.md
│   ├── friction-classified.json   ← machine-readable friction (pattern + recurrence)
│   ├── forge-active                ← session marker (JSON when active, empty when off)
│   ├── wind-down-phrases.json      ← learned personal end-of-day vocabulary
│   ├── wellness-preferences.json   ← wellness coach config (when enabled)
│   ├── wellness-runtime.json       ← wellness runtime state (gitignored)
│   ├── calendar-sync-state.json    ← updatedMin token for cheap calendar delta-checks
│   ├── decisions/                  ← decisions that span projects
│   ├── patterns/                   ← cross-project codebase wisdom (rare)
│   └── tasks/{open,resolved}/      ← cross-cutting tasks (_shared behaves
│                                       like another project for tasks)
├── _templates/             ← Obsidian note templates (task, umbrella, decision, pattern, ...)
└── {ENV}/{project}/        ← per-project (env optional for single-environment setups)
    ├── INDEX.md
    ├── current-checkpoint.md
    ├── braindump.md
    ├── BACKLOG.md          ← single-page prioritized view (Keeper-curated)
    ├── decisions/          ← created on demand
    ├── architecture/       ← created on demand
    ├── patterns/           ← project-specific gotchas (lifted from PR reviews via /promote-from-review)
    └── tasks/
        ├── open/           ← active tasks (single-doc workflow)
        ├── resolved/       ← completed tasks (auto-archived by Keeper)
        ├── draft/          ← 5-second Obsidian captures (triaged at weekly wrap)
        └── reviews/        ← PR review docs (lifecycled by reviewed-PR sync + /promote-from-review)
```

Cross-project synthesis (a former `_shared/OVERVIEW.md` + `_shared/current-checkpoint.md`) was explicitly removed per decision `2026-06-01-petra-single-project-scope`. Petra's day-to-day attention is bounded to one project; cross-project work happens at the weekly wrap, on-demand at user request, or via direct vault folder browsing.

Forge install state lives in `~/.claude/` (forge.conf, settings backup). The `forge-active` runtime marker lives in the vault at `${VAULT_PATH}/_shared/forge-active` instead — `~/.claude/` is a Claude Code sensitive zone where allowlist patterns can't suppress prompts (see `core/references/permission-patterns.md` pitfall #5), and the marker needs silent writes on every Forge entry/exit. Wellness preferences (`${VAULT_PATH}/_shared/wellness-preferences.json`) follow the same relocation pattern, for the same reason.

The full set of `~/.claude/settings.json` permissions that `install.sh` writes — every script, hook, vault path, and conditional wellness pattern Forge needs — is catalogued in `core/references/forge-permissions.md`. That file is the source of truth for the install-time baseline; `forge-permission-lint.sh` validates the baked patterns at install end (fail-closed).

See [PROJECT-STRUCTURE.md](PROJECT-STRUCTURE.md) for the per-project layout.

## Agent Roles

Roles are behaviours, not separate agents. Output uses two layers:

- **Block header** — `[Forge: ENV/Project | HH:MM]` on its own line at the top of every response. ENV is the vault env folder (`PRO`, `PERSO`, etc.); use the project name and `forge` for forge-level work. The `inject-current-time.sh` UserPromptSubmit hook supplies both the current HH:MM and the literal expected prefix string at every prompt, so the header doesn't depend on Claude assembling it from memory — the hook reads the active marker, resolves ENV from vault structure, and injects e.g. `[Forge active for forge — begin your response with: ​`[Forge: PERSO/forge | 16:11]​`]` as authoritative context.
- **Role voice** — lighter per-paragraph attribution. `Petra:` for conversational voice. `[Keeper]`, `[Refiner]`, etc. for role status tags. Not every paragraph needs attribution.

| Role | Backed by | Responsibility |
|------|-----------|---------------|
| **Forge Master (Petra)** | `forge`, `forge-checkpoint`, `forge-exit` skills | Runs the session — vault loading, PR sync, delegation, work planning, wrap-up |
| **Keeper** | `keeper` skill | Decisions, checkpoints, scope monitoring, INDEX maintenance |
| **Refiner** | `refiner` skill | Friction → root cause → fix proposal → friction log |
| **Reviewer** | `plan-reviewer` skill, pr-review-toolkit agents, code-review | Plan validation, code review, test coverage |
| **Impl** | superpowers skills (TDD, executing-plans, subagent-driven-dev) | Implementation following validated plans |
| **Architect** | brainstorming, writing-plans | Design, tradeoff analysis, specs |
| **Debugger** | systematic-debugging | Structured root cause analysis |
| **Release Manager** | finishing-a-development-branch, commit-push-pr | Verification, commits, PRs |
| **Toolsmith** | writing-skills | Building and improving skills |

**Proactive roles** (always active in Forge mode):
- **Keeper** — logs decisions when validated, writes checkpoints at natural pauses, reconciles PRs on each checkpoint
- **Refiner** — activates on any user correction, before continuing with the corrected approach

**Agent-team modes.** For work that genuinely benefits from parallel collaboration, Petra can spawn a team instead of dispatching subagents sequentially:

- **Pattern A** — pair of different roles on the same artifact (e.g. Reviewer + Refiner on a PR)
- **Pattern B** — multiple instances of the same role with competing hypotheses (e.g. 3-5 Debuggers on an unclear root cause)
- **Pattern C** — same role, scope-partitioned (e.g. Reviewers split across security / performance / test coverage)

Most Forge work doesn't need teams — sequential subagent dispatch is the default. Teams require `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` (Claude Code v2.1.32+) and tmux; falls back to inline sequential dispatch when the substrate is missing. Full pattern protocol: `core/references/agent-teams-mode.md`.

For per-role specifications (proactive flag, vault interaction, etc.), see [ROLES.md](ROLES.md).

## Friction framework

Converts recurrent friction events (permission prompts, prose-discipline failures, role drift) into named patterns with deterministic script-enforced mitigations. Aim: stop relying on prose rules ("remember to do X") for things that recur — script them instead.

**Components:**

| Component | Where | Purpose |
|---|---|---|
| Pattern catalog | `core/references/script-replacement-patterns.md` | 5 named patterns with when-to-use, how-it-works, exemplars, anti-patterns, scaffolds |
| Classifier decision tree | `core/references/friction-classifier.md` | Maps friction shape → pattern slug (or `needs_new_pattern`) |
| Classifier script | `adapters/claude-code/scripts/forge-classify-friction.sh` | Non-interactive keyword routing — emits pattern + action-ref |
| `append-friction` subcommand | `adapters/claude-code/scripts/forge-context.sh` | Writes structured entry to friction-log + classified JSON; auto-creates stub task at recurrence=1; marker-driven action-ref prefix routes forge-on-forge friction to the project subtree |
| `audit-prose-rules` subcommand | `adapters/claude-code/scripts/forge-context.sh` | Scans for MUST/Never/always-style prose in skills/scripts; cross-references friction-log for recurrence signal |
| `/forge-audit` slash command | `adapters/claude-code/skills/forge-audit/` | User-invocable wrapper over `audit-prose-rules` |
| Refiner protocol extension | `adapters/claude-code/skills/refiner/SKILL.md` step 5 | Classification handoff to `append-friction` when a friction surfaces |
| Bootstrap retro-classify | `adapters/claude-code/scripts/forge-context.sh bootstrap-classify` | One-shot retrofit of the historical friction-log into structured JSON |

**Data flow:** User correction → Refiner identifies root cause → `forge-classify-friction.sh` returns pattern + action-ref → `forge-context.sh append-friction` writes to `_shared/friction-log.md` (human-readable) + `_shared/friction-classified.json` (machine-readable) + auto-creates stub task at recurrence=1.

**Error handling:** `append-friction` uses write-then-flag — on pattern validation failure, the entry is still written with `validation_failed: true` and `pattern: unknown`, and the subcommand exits non-zero. Refiner can then surface the failure rather than swallow it.

**Spec & rationale:** the full design, decision history, and rollout walkthrough live in the maintainer's vault; the pattern catalog (`core/references/script-replacement-patterns.md`) and classifier tree (`core/references/friction-classifier.md`) are the parts shipped to users.

## Petra — The Forge Master

Defined in `~/.claude/skills/forge/SKILL.md`. Persona inspired by Petra Forgewoman (Horizon series, Oseram tribe) — inside joke, not cosplay. Fixed vocabulary of forge metaphors. Surfaces at session entry/exit, checkpoints, friction, milestones. Stays silent during implementation, code output, test results.

## Wellness Coach

Optional Forge module — bundled with Forge but disabled unless the user opts in during onboarding. Separate authority from Petra: one-way dependency (Petra reads wellness state, wellness knows nothing about Forge).

- **Skill:** `wellness-coach` — onboarding, break handling, persona, conversational queries
- **Hooks:**
  - `wellness-timer.py` (PreToolUse **+ Stop**) — break timer, escalation, strike. Stop tick covers Pattern A workflows where PreToolUse fires too rarely (user reading long agent output). Strike under Stop sets state; next PreToolUse enforces the actual block. Schedule-aware defer: real-break nags + strikes skip when the user is in or imminently entering a meeting (gated on `forge-calendar.sh in-meeting` + `next-meeting 5`).
  - `wellness-precompact.py` (PreCompact) — break suggestion during compaction
- **Daemon:** `idle-sampler.py` (launchd, 60s interval) — samples screen state when activity monitor is enabled. Marker-gated: reads `${VAULT_PATH}/_shared/forge-active` each tick and exits early when no Forge session is active. Aligns with the principle "Forge should not behave as if it monitors when not running."
- **Scripts:** `weather.sh`, `wellness-reset.sh`, `wellness-status.sh`, `wellness-stale-clear-guard.sh`, `install-monitor.sh` + `uninstall-monitor.sh`, `notify.sh`
- **Runtime state:** `${VAULT_PATH}/_shared/wellness-preferences.json` (user config, tracked) + `${VAULT_PATH}/_shared/wellness-runtime.json` (auto-modified, gitignored — `last_break_timestamp`, `strike_active`, etc.)

Petra uses wellness state for break-aware work planning (steer away from deep work near interruptions) and end-of-day wrap-up (quiet time via timestamp reset).

## Knowledge Base Integration (optional)

Projects can optionally reference an external knowledge base repo in their vault INDEX.md (`## Knowledge Base` section). When present, Forge:

- Pulls latest and scans filenames at session start for topic awareness
- Pulls before reading content during work (teammates may have pushed)
- Consults relevant decisions/specs before proposing architecture approaches
- Offers to contribute decisions and specs back, following the KB's git flow

This is project-specific — only affects projects that declare a KB. No impact on projects without one.
