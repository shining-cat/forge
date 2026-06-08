# Vault Write Protocol — Subagent Dispatch as Default

Loaded by the `forge` skill from the "Proactive Keeper" section. Governs the mechanism Petra (and any Forge role) uses when writing to the vault.

## Why subagent dispatch is the default

The user reads vault content in Obsidian, side-by-side with the terminal running Claude Code. When Petra writes via inline `Write`/`Edit` tool calls, Claude Code renders the full red/green diff in the conversation — same content the user already sees in Obsidian, but in a less ergonomic surface, and large enough to push the conversational reply off-screen. The conversational exchange is the high-value output; the diff is scaffolding.

Subagent dispatch hides that diff. The subagent's `Write`/`Edit` tool calls render collapsed under the parent's Agent invocation block, not as in-conversation diffs. Spike 2026-06-08 (`[[2026-06-08-quiet-forge-vault-writes]]`) confirmed: Claude Code 2.1+ subagents inherit parent-session vault Write permissions (no extra prompt), and tool calls stay contained inside the agent block.

## When to use subagent dispatch

Any vault `Write`/`Edit` that would produce visible diff render in the parent conversation. This covers: checkpoint writes, BACKLOG refreshes, task file writes / status edits, INDEX updates, decision files, architecture notes, template instantiations.

Dispatch a `forge-keeper` (or other role-appropriate Forge subagent) with the full edit instructions in the prompt. The subagent does the writes; the parent conversation sees one collapsed Agent block.

## When inline is OK

Small targeted Edits where subagent overhead isn't worth the saved noise — a 2-line frontmatter timestamp bump, especially right after context compression (when re-orienting via inline Read is already on the critical path and a quick Edit follows). Keep inline edits as small as possible (smallest Edit, never re-Write a whole file for a small change).

After context compression, the inline Read of `current-checkpoint.md` to reorient is unchanged — reading is always inline; the protocol here is about *writes* that produce diff render.

## When to use `forge-context.sh` subcommands instead

Append-style operations on known files have dedicated subcommands and should keep using them — they're cheaper than spinning up a subagent and quieter than inline Write:

- `forge-context.sh append-friction` — friction log entries
- `forge-context.sh append-braindump` — braindump entries
- `forge-context.sh resolve-task` — flip task status to resolved
- `forge-context.sh mark-weekly-wrap-done` — weekly wrap state

These render as a single Bash command line in the conversation, not a file diff.

## How to batch

Multiple vault edits in ONE subagent dispatch is strictly better than N Agent calls. The subagent does all the writes; the parent conversation sees one collapsed Agent block instead of N. When a BACKLOG refresh needs three Edits (frontmatter date + row update + row remove), dispatch ONE subagent with all three instructions in the prompt.

Background dispatch (`run_in_background: true`) is still opt-in and requires user authorization — its permission flow has no UI surface for prompts, so a background subagent that hits an unprompted permission will silently deny.

## What the spike proved (2026-06-08)

Foreground `forge-keeper` subagent dispatched to Write a 380-byte test file into `${VAULT_PATH}/_shared/_meta/spike-test-2026-06-08.md`. Result: no permission prompt (subagent inherits parent vault-write permissions), no diff render in parent conversation (Write contained inside the agent invocation block). Direction locked. Spike artifact archived under `_shared/_meta/_discarded/`. Full audit trail: `[[2026-06-08-quiet-forge-vault-writes]]`.
