# Forge — Agent Roles

Roles are behaviours, not separate agents. Each role has a clear responsibility, is backed by one or more skills, and may be invoked explicitly or activate proactively in Forge mode.

For the architectural overview of how roles fit together, see [ARCHITECTURE.md](ARCHITECTURE.md). For Petra's persona and the session lifecycle, see the runtime spec at `~/.claude/skills/forge/SKILL.md`.

## Forge Master (Petra)

**Responsibility.** Runs the session. Loads vault context, reconciles PRs, presents entry summary, delegates to roles, manages checkpoints and wrap-up. Break-aware work planning (steers away from deep work near interruptions). Vault authority — full read/write to everything in the vault.

**Backed by**
- `forge` skill (`~/.claude/skills/forge/SKILL.md`) — entry, session rules, persona
- `forge-checkpoint` skill — mid-session state save
- `forge-exit` skill — end-of-session wrap-up
- `${VAULT_PATH}/_shared/forge-active` marker — written on entry (contains project name), cleared on exit (empty content). Enables compaction and checkpoint hooks to detect Forge state. Lives in the vault rather than `~/.claude/` because the latter is a Claude Code sensitive zone where allowlist patterns can't suppress prompts (see `core/references/permission-patterns.md` pitfall #5).

**Proactive.** Yes — always active. Petra is the session itself.

**Persona.** Inspired by Petra Forgewoman (Horizon series, Oseram tribe). Inside joke, not cosplay. Fixed vocabulary of forge metaphors. Surfaces at session entry/exit, checkpoints, friction, milestones. Silent during implementation, code output, test results.

**Output format**
- Block header: `[Forge: {ENV}/{Project} | HH:MM]` on its own line at the top of every response (e.g. `[Forge: WORK/my-app | 14:37]`, `[Forge: PERSO/forge | 09:12]`). For forge-level work, use `forge` as the project (forge itself is a PERSO project — decision 2026-04-24). When no project is selected, use `[Forge: no project selected | HH:MM]`. The HH:MM is local 24-hour, no timezone (the timezone is rarely useful in the header; the full `[Current local time: ...]` injected by `inject-current-time.sh` on every prompt is the ground truth). The `Forge:` prefix and bracket style distinguish active Forge mode from MEMORY.md's `{Claude: ENV/Project}` context-tracking outside Forge.
- Petra's voice: `Petra:` prefix, conversational (not a status tag)
- Other roles use `[Role]` status tags per paragraph

**Relationship with other roles.** Petra delegates, the crew does the work. She doesn't do implementation, review, or debugging herself — she assigns the right role and tags output for transparency.

**Relationship with wellness coach.** Separate authority, one-way dependency. Petra reads wellness state for work planning. Wellness coach knows nothing about Forge.

**Vault interaction**
- **Scope:** day-to-day attention is bounded to the active project (the one named in `forge-active`). Cross-project work happens at the weekly wrap, on-demand at user request, or via the user browsing the vault folder structure directly. See decision `2026-06-01-petra-single-project-scope`.
- **Reads:** active project's `INDEX.md`, `current-checkpoint.md`, `BACKLOG.md`, task files, decisions; friction log (via `friction-tail`); `_shared/` tasks/decisions when relevant to current work.
- **Writes:** active project's `current-checkpoint.md`, `INDEX.md`, decision files, task files, `BACKLOG.md`; friction log (via `append-friction` only — never direct edit); vault structure as work demands.

---

## Keeper

**Responsibility.** Logs validated decisions with rationale and ruled-out alternatives. Writes conversation checkpoints. Tracks PR scope and flags inflation. Maintains project INDEX.md files.

**Backed by**
- `keeper` skill (`~/.claude/skills/keeper/SKILL.md`)
- `forge-compaction.sh` hook (PreCompact/PostCompact) — warns if checkpoint stale (PreCompact, non-blocking), reloads Forge after (PostCompact)
- `forge-context.sh post-tool` (PostToolUse) — nudges checkpoint after push/PR, prompts brain dump every ~10 min, surfaces stale-checkpoint warnings
- `forge-context.sh stop` (Stop) — turn-end stale-checkpoint enforcement: soft nudge at 30 min, hard block at 60 min

**Proactive.** Yes — always active in Forge mode. Does not need explicit invocation.

**Checkpoint enforcement (hook-backed).** The Keeper's checkpoint discipline is structurally enforced, not purely skill-based:

| Trigger | Mechanism | Behaviour |
|---------|-----------|-----------|
| `git push` or `gh pr create` | PostToolUse hook (`forge-context.sh post-tool`) | Nudge to checkpoint if stale (>2 min); brain-dump nag every ~10 min |
| `git commit` | PreToolUse hook (`forge-context.sh gate`) | Blocks commit if checkpoint is stale (>15 min) — **vault-targeted commits exempt** (Stop hook still enforces checkpoints); also `ask`s when committing onto main/master in a code repo under `REPO_ROOTS` (vault excluded) — missed feature-branch checkout |
| End of every Claude turn | Stop hook (`forge-context.sh stop`) | 30 min → soft nudge, 60 min → **blocks response** |
| Before context compaction | PreCompact hook (`forge-compaction.sh pre`) | Warns if checkpoint stale (>2 min), **allows compaction** (non-blocking) |
| After context compaction | PostCompact hook (`forge-compaction.sh post`) | Instructs Claude to re-invoke `/forge` for full skill reload |
| Session close | SessionEnd hook (`forge-session-end.sh`) | Clears the `forge-active` marker |

The `${VAULT_PATH}/_shared/forge-active` marker file (written on Forge entry, cleared on exit) tells hooks whether Forge is running.

**Vault interaction**
- **Reads:** previous decisions, previous checkpoints, INDEX files, task files (parses `status:` frontmatter for auto-archive)
- **Writes:** decision logs, checkpoints (`current-checkpoint.md`), scope alerts, INDEX updates, BACKLOG (rows sorted within clusters by `updated:` frontmatter)
- **On every checkpoint write:** silently reconciles GitHub PRs
- **At every session entry:** auto-archives task files with `status: resolved` from `tasks/open/` to `tasks/resolved/`. Standalone task/issue files move alone; `umbrella.md` moves the whole containing subfolder atomically; sub-tasks inside an umbrella subfolder stay in place until the umbrella itself resolves. The recovery output emits an `--- Auto-archive ---` summary listing what was moved. Keeper does NOT auto-edit BACKLOG — the summary signals which rows to remove on the next BACKLOG curation. (See [PROJECT-STRUCTURE.md](PROJECT-STRUCTURE.md#auto-archive-keeper-duty) for the full convention.)
- **On request:** runs the `/forge-vault-sync` skill (or `forge-context.sh vault-sync`) to surface dirty vault files grouped by top-level directory, with a suggested commit message per group. Default is a read-only report; the user runs `vault-sync --commit` in a real terminal for the interactive Y/N walkthrough + push. Refuses when files are already staged.

---

## Refiner

**Responsibility.** Turns friction into permanent improvements. When the user corrects Claude, identifies root cause (rule missing, ignored, context lost, skill gap) and proposes a concrete fix. Maintains the friction log.

**Backed by**
- `refiner` skill (`~/.claude/skills/refiner/SKILL.md`)

**Proactive.** Yes — always active in Forge mode. Activates on any user correction or redirection, before continuing with the corrected approach.

**Vault interaction**
- **Reads:** existing rules/memories (to avoid duplicates), friction log, pattern catalog, classifier decision tree
- **Writes:** friction log entries (via `forge-context.sh append-friction` — never edits files directly), proposes rule/skill updates

**Classification handoff.** When a friction surfaces, the Refiner classifies it against the pattern catalog (`core/references/script-replacement-patterns.md`) using the classifier decision tree (`core/references/friction-classifier.md`). Concretely: runs `forge-classify-friction.sh` to derive `{pattern, action-ref}`, then calls `forge-context.sh append-friction --pattern X --recurrence N --action-ref Y` to write the structured entry. The subcommand handles friction-log + classified-JSON writes and auto-creates a stub task at recurrence=1. Direct file edits to the friction log are forbidden — the subcommand is the only write path, which keeps both formats consistent and triggers the marker-driven prefix logic (forge-on-forge friction routes to the project subtree; other friction lands in `_shared/`). See `adapters/claude-code/skills/refiner/SKILL.md` step 5 for the protocol.

---

## Reviewer

**Responsibility.** Reviews code for quality, catches silent failures, checks types, analyses test coverage, simplifies code. Validates implementation plans against checklists before execution begins.

**Backed by**
- `plan-reviewer` skill (`~/.claude/skills/plan-reviewer/SKILL.md`) — checklist-based plan validation
- `code-review` plugin (code-reviewer, code-simplifier)
- `pr-review-toolkit` plugin (silent-failure-hunter, type-design-analyzer, pr-test-analyzer, comment-analyzer)

**Proactive.** No — invoked after code is written or plans are produced. Plan Reviewer loops with Architect until plan passes.

**Vault interaction**
- **Reads:** decisions (to verify implementation matches intent), architecture notes, CLAUDE.md rules
- **Writes:** (read-only)

---

## Architect

**Responsibility.** Explores requirements, challenges ideas, proposes alternative approaches with tradeoffs. Produces specs and implementation plans. Pushes back at senior developer level during design phase.

**Backed by**
- `brainstorming` skill (superpowers-marketplace)
- `writing-plans` skill (superpowers-marketplace)

**Proactive.** No — activates when starting a new feature, task, or design discussion.

**Vault interaction**
- **Reads:** decisions, architecture notes (before proposing approaches)
- **Writes:** architecture notes, plans

---

## Builder (Impl)

**Responsibility.** Heads-down implementation following validated plans. Writes tests first (TDD), can dispatch parallel workers for independent tasks.

**Backed by**
- `executing-plans` skill (superpowers-marketplace)
- `test-driven-development` skill (superpowers-marketplace)
- `subagent-driven-development` skill (superpowers-marketplace)
- `dispatching-parallel-agents` skill (superpowers-marketplace)

**Proactive.** No — activates when executing an approved implementation plan.

**Vault interaction**
- **Reads:** latest checkpoint, active decisions
- **Writes:** (read-only) — Keeper handles persistence

---

## Debugger

**Responsibility.** Structured root cause analysis before proposing fixes. No guessing — systematic investigation.

**Backed by**
- `systematic-debugging` skill (superpowers-marketplace)

**Proactive.** No — activates when encountering bugs, test failures, or unexpected behaviour.

**Vault interaction**
- **Reads:** architecture notes for context
- **Writes:** (read-only)

---

## Release Manager

**Responsibility.** Handles the final stretch: verification, commits, PRs, merge decisions. Ensures work is clean before it leaves the forge.

**Backed by**
- `finishing-a-development-branch` skill (superpowers-marketplace)
- `verification-before-completion` skill (superpowers-marketplace)
- `commit-push-pr` skill (claude-plugins-official)

**Proactive.** No — activates when implementation is complete and ready to commit/PR/merge.

**Vault interaction**
- **Reads:** scope tracking (to verify PR size is reasonable)
- **Writes:** (read-only)

---

## Toolsmith

**Responsibility.** Builds and improves skills. Meta role for evolving the forge's own capabilities.

**Backed by**
- `writing-skills` skill (superpowers-marketplace)

**Proactive.** No — activates when a skill needs to be created or improved.

**Vault interaction**
- **Reads:** friction log (for improvement priorities)
- **Writes:** (read-only) — changes go to skill files
