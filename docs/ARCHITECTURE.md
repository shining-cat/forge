# Forge — Architecture

What Forge IS — its components, how they fit together, and the principles that drive it. For the high-level pitch and install instructions, see the [README](../README.md). For per-role details, see [ROLES.md](ROLES.md). For vault project layout conventions, see [PROJECT-STRUCTURE.md](PROJECT-STRUCTURE.md).

## Philosophy

1. **Visibility** — All accumulated knowledge is browsable in Obsidian
2. **Reliability** — Decisions persist across and within conversations
3. **Self-improvement** — Friction events feed back as permanent improvements

The human is the architect and decision-maker. Agents execute, challenge during design, and maintain knowledge.

## Components

The forge is assembled from Claude Code building blocks:

| Component | Type | What it does |
|-----------|------|-------------|
| `forge` | Skill | Entry point — loads vault, syncs PRs, activates Petra and session rules |
| `forge-checkpoint` | Skill | Mid-session state save |
| `forge-exit` | Skill | End-of-session wrap-up |
| `keeper` | Skill | Decision logging, checkpoints, scope monitoring, INDEX maintenance |
| `refiner` | Skill | Friction detection, root cause analysis, rule proposals |
| `plan-reviewer` | Skill | Checklist-based plan validation |
| `wellness-coach` | Skill + Plugin | Break reminders, escalation, strike enforcement (optional) |
| `wellness-timer.py` | Hook (PreToolUse) | Runtime break timer — injects reminders, blocks tools on strike |
| `approval-notifier.sh` | Hook (PreToolUse) | Notification on tool approval prompts |
| `forge-compaction.sh` | Hook (PreCompact + PostCompact) | Warns if checkpoint stale (PreCompact), reminds to reload Forge after (PostCompact) |
| `forge-checkpoint-nudge.sh` | Hook (PostToolUse + Stop) | Nudges checkpoint after push/PR, blocks after 60 min staleness |
| `settings.json` | Config | Hook wiring, permissions, plugin enablement |
| `statusline.sh` | Config | Status bar showing session state |

### Where components live

| Location | Content |
|----------|---------|
| `~/.claude/skills/{name}/SKILL.md` | Skill definitions (forge, forge-checkpoint, forge-exit, keeper, plan-reviewer, refiner, wellness-coach) |
| `~/.claude/skills/forge/references/` | Forge skill references (vocabulary.md, lifecycle.md, wellness-awareness.md) — loaded on-demand from main SKILL.md |
| `~/.claude/hooks/` | Hook scripts (approval-notifier.sh, forge-compaction.sh, forge-checkpoint-nudge.sh) |
| `~/.claude/plugins/marketplaces/{marketplace}/plugins/wellness-coach/` | Wellness coach plugin (hook, scripts, preferences module) |
| `~/.claude/settings.json` | Hook configuration, permissions, plugin enablement |
| `~/.claude/wellness-preferences.json` | Wellness coach runtime state |
| `~/.claude/forge-active` | Marker file (contains project name, empty when deactivated) |
| `~/.claude/forge.conf` | Per-install configuration (vault path, repo path, model assignments) |
| `{vault}/` | Knowledge vault (see [Vault Structure](#vault-structure)) |

### External dependencies

Skills reference capabilities from these marketplaces:

| Marketplace | Skills used by forge roles |
|-------------|--------------------------|
| `superpowers-marketplace` | brainstorming, writing-plans, systematic-debugging, writing-skills, finishing-a-development-branch, verification-before-completion, executing-plans, test-driven-development, subagent-driven-development, dispatching-parallel-agents, requesting-code-review, receiving-code-review, using-git-worktrees |
| `claude-plugins-official` | code-review (code-simplifier, code-reviewer), commit-commands (commit, commit-push-pr), pr-review-toolkit (review-pr, silent-failure-hunter, type-design-analyzer, pr-test-analyzer, comment-analyzer) |
| Optional / org-specific | wellness-coach (hook + scripts), google-workspace, jira, developer-documentation |

## Vault Structure

```
{vault}/
├── _shared/                ← runtime work (personal, cross-project)
│   ├── OVERVIEW.md         ← cross-project awareness (slow-changing)
│   ├── current-checkpoint.md ← cross-project work in progress
│   ├── friction-log.md
│   ├── decisions/          ← cross-project decisions
│   ├── tasks/{open,resolved}/
│   └── learnings/
├── _templates/             ← Obsidian note templates
└── {ENV}/{project}/        ← per-project (env optional for single-environment setups)
    ├── INDEX.md
    ├── current-checkpoint.md
    ├── braindump.md
    ├── decisions/          ← created on demand
    └── architecture/       ← created on demand
```

Forge install state lives outside the vault, in `~/.claude/` (forge.conf, forge-active, wellness-preferences.json).

See [PROJECT-STRUCTURE.md](PROJECT-STRUCTURE.md) for the per-project layout.

## Agent Roles

Roles are behaviours, not separate agents. Output uses two layers:

- **Block header** — `[Forge | {PROJECT}]` on its own line at the top of every response. Use the project name, `forge` for forge-level work, or `No project selected`.
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

For per-role specifications (proactive flag, vault interaction, etc.), see [ROLES.md](ROLES.md).

## Petra — The Forge Master

Defined in `~/.claude/skills/forge/SKILL.md`. Persona inspired by Petra Forgewoman (Horizon series, Oseram tribe) — inside joke, not cosplay. Fixed vocabulary of forge metaphors. Surfaces at session entry/exit, checkpoints, friction, milestones. Stays silent during implementation, code output, test results.

## Wellness Coach

Optional companion. Separate authority from Petra — one-way dependency (Petra reads wellness state, wellness knows nothing about Forge).

- **Skill:** `wellness-coach` — onboarding, break handling, persona, conversational queries
- **Plugin module:** hook (`wellness-timer.py`), scripts (weather, activity monitor install)
- **Runtime state:** `~/.claude/wellness-preferences.json`

Petra uses wellness state for break-aware work planning (steer away from deep work near interruptions) and end-of-day wrap-up (quiet time via timestamp reset).

## Knowledge Base Integration (optional)

Projects can optionally reference an external knowledge base repo in their vault INDEX.md (`## Knowledge Base` section). When present, Forge:

- Pulls latest and scans filenames at session start for topic awareness
- Pulls before reading content during work (teammates may have pushed)
- Consults relevant decisions/specs before proposing architecture approaches
- Offers to contribute decisions and specs back, following the KB's git flow

This is project-specific — only affects projects that declare a KB. No impact on projects without one.
