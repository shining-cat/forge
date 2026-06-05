# Forge — Command Reference

The user-facing slash commands. Most you won't type by hand — Petra surfaces them when the moment is right. This reference is for when you want to invoke them deliberately or look up what they do.

For the day-walkthrough that shows how these fit together, see the [README](../README.md). For session-rule internals, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Entering and exiting a session

| Command | What it does |
|---|---|
| `/forge` | **Enter Forge mode.** Loads the active project's vault, reconciles your open + reviewed PRs against GitHub, surfaces calendar interruptions for the day, flags merged review docs ripe for cleanup. Cold-start after a long gap (>~4h, configurable) gets a special banner reminding you not to trust the checkpoint implicitly. |
| `/forge-exit` | **Wrap the session.** Writes a final checkpoint, deactivates the active-project marker, resets the wellness break clock. Hooks stop firing into a dead session. Also triggered conversationally by phrases like *"done for today"* / *"calling it"* / *"logging off"*. |
| `/forge-weekly` | **Friday wrap ceremony.** The Quartermaster persona harvests the week's friction into structured patterns, triages captured drafts into proper tasks, runs the cross-project retro, logs the week. Usually run before `/forge-exit` on a Friday afternoon. |

## During work

| Command | What it does |
|---|---|
| `/forge-checkpoint` | **Write a checkpoint manually.** Keeper writes them automatically at natural pause points (task done, topic shift, before long operations) — use this when you want to force one (before a complex operation, or before stepping away). |
| `/forge-vault-sync` | **Commit + push the vault when drift accumulates.** Default is a read-only report grouping dirty files by top-level directory with a suggested commit message per group. Run `forge-context.sh vault-sync --commit` in a real terminal for the interactive Y/N walkthrough + push. |
| `/promote-from-review <pr-num>` | **Extract patterns from a merged PR's review doc, then clean up.** Walks you through identifying durable pattern candidates (non-obvious gotchas, repeatable failure modes) and scaffolds `patterns/<slug>.md` files from the template before deleting the review doc. **Conservative defaults**: never auto-writes a pattern, never auto-deletes a doc — always confirms. Surfaced by the entry-time reviewed-PR sync; can also be invoked manually any time. |

## Audits (mostly maintainer-mode oriented)

| Command | What it does |
|---|---|
| `/forge-audit` | Scan skills/scripts for MUST/Never/always-style prose patterns; cross-references the friction log for recurrence signal. Surfaces candidates for script-replacement of repeated rule violations. |
| `/forge-audit-permissions` | Run the permission-pattern linter against `~/.claude/settings.json`. Surfaces anti-patterns (single-`*` not crossing `/`, leading-`*` literals, sensitive-zone overrides that won't take). Same linter that runs at install end (fail-closed). |

## Conversational triggers (not slash commands)

A few things happen via prose, not a command:

| What you say | What happens |
|---|---|
| *"log this for later: ..."* / *"remember this: ..."* / similar | Petra dumps the idea into the brain-dump or files a quick task stub in the right project, without breaking your current thread. |
| *"done for today"* / *"calling it"* / *"logging off"* / similar | Triggers a `/forge-exit` offer. Also resets the wellness break clock silently (you're winding down either way). The personal wind-down phrase list is learned over time. |
| *"{coach_name}, lift the strike, I'm on lunch"* (or any address-by-name during an active wellness strike) | Invokes the wellness-coach skill, lifts the strike, walks through the strike-conversation flow to decide whether to credit a real break. |
| *"add project"* / *"add environment"* | Walks through vault scaffolding for a new project or environment layer. |

These are taught by the day-walkthrough in the README — they're things the user initiates, not things Petra surfaces mid-session.

## `forge-context.sh` — direct subcommand invocations (less common)

`forge-context.sh` has ~30 subcommands. Most are wired into Claude Code hooks and surface automatically; a handful are useful to invoke directly from the shell when you want a one-off check or report:

```bash
# Audits (one-off — also surface at session entry in maintainer mode)
~/.claude/scripts/forge-context.sh open-task-audit         # stale tasks not in checkpoint
~/.claude/scripts/forge-context.sh backlog-audit           # BACKLOG drift signals
~/.claude/scripts/forge-context.sh audit-prose-rules       # MUST/Never/always-style scan
~/.claude/scripts/forge-context.sh review-sync             # merged review-doc cleanup queue (active project)
~/.claude/scripts/forge-context.sh review-sync --backfill  # ...across all projects (first-deploy cleanup)
~/.claude/scripts/forge-context.sh framework-budget        # measure framework entry tax
~/.claude/scripts/forge-context.sh skill-budgets           # per-skill byte/token cost

# Calendar awareness
~/.claude/scripts/forge-context.sh next-meeting            # next non-declined meeting within MEETING_WINDOW_MIN

# Rollback artifacts
~/.claude/scripts/forge-context.sh rollback-install list   # inventory backup artifacts under ~/.claude/
~/.claude/scripts/forge-context.sh rollback-install restore <path>
~/.claude/scripts/forge-context.sh rollback-install accept-upstream <path>
~/.claude/scripts/forge-context.sh rollback-install clean --keep-last 3

# Personal wind-down phrase list
~/.claude/scripts/forge-context.sh wind-down-list          # show learned end-of-day phrases
```

Companion scripts:

```bash
~/.claude/scripts/forge-cost-snapshot.sh           # human-readable cost snapshot of current session
~/.claude/scripts/forge-cost-snapshot.sh --json    # machine-readable
~/.claude/scripts/forge-calendar.sh entry-fetch    # today's agenda (used by /forge entry)
~/.claude/scripts/forge-calendar.sh in-meeting     # presence-only: are you in a meeting right now
```

Full subcommand list (also printed by running `~/.claude/scripts/forge-context.sh` with no args):

```
post-tool | gate | stop | recover | reconcile-marker | status |
vault-sync | wrap-up-state | weekly-wrap-due | mark-weekly-wrap-done |
check-install | rollback-install | open-task-audit | backlog-audit |
set-marker | append-braindump | append-friction | friction-tail |
pin-friction | archive-friction-entries | harvest-friction |
promote-friction | bootstrap-harvest | audit-prose-rules |
skill-budgets | framework-budget | bootstrap-classify | resolve-task |
learn-wind-down | wind-down-list | next-meeting | substrate-check |
review-sync | draft-list
```

The hook-wired subcommands (`post-tool`, `gate`, `stop`, `recover`, `reconcile-marker`, `status`) fire automatically and aren't typically invoked by hand. The rest are user-callable for one-off checks or reports.
