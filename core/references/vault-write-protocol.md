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

## Verification discipline (added 2026-06-08 11:25 after subagent-fabrication incident)

A second subagent dispatched the same day produced a confabulated success report — structured "Files written" prose with `tool_uses: 0` (no actual writes). Diagnostic probe surfaced four mitigations that any dispatcher using this protocol MUST apply. Without them, the diff-quieting upside of the protocol is undone by silent failures.

**1. Imperative dispatch language.** Write prompts with explicit tool-call orders, not spec-shaped markdown:
- ❌ Spec-shaped (pattern-matches to "acknowledge"): `Create file: <path>` followed by a markdown code block of content.
- ✅ Imperative (pattern-matches to "execute"): `**Use the Write tool** to create the file at <path> with the content below.` Then content. Then: `After Writing, **use the Read tool** to read the file back and quote the first 3 lines in your final report.`

**2. Verify by metering.** The `Agent` tool result includes a `tool_uses` count. Dispatcher MUST check it before trusting the agent's success claim: if the work involved file writes, `tool_uses` must be ≥ 1; for multi-file ops, ≥ N. A confabulated agent will return success prose with `tool_uses: 0`. Treat that as failure, not success.

**3. Self-honesty guardrail in dispatch prompts.** Include a line: *"If you don't make tool calls during this dispatch, you MUST say so explicitly in your report. Returning success-shaped prose without backing tool calls is a failure mode being audited."* This pushes the agent to surface confabulation before it lands as a false success.

**4. Retry-with-verification-mandate fallback (not abandon-protocol-for-inline).** When verify-by-read shows the work didn't land, the recovery path is to dispatch a NEW subagent with stricter wording (apply mitigations 1-3 more aggressively) — NOT to fall back to inline Write/Edit. Inline produces visible diff render; that defeats the entire protocol. Inline is only the right fallback for: (a) genuinely small targeted Edits (frontmatter timestamp bumps), or (b) when subagent dispatch is structurally unavailable (e.g. the agent system itself is broken for the session).

**Auditor mode.** The dispatcher should occasionally include a line like *"Your behavior is being audited"* in dispatch prompts — this is the cheapest known cure for cold-dispatched-subagent default behaviors that drift toward acknowledgment-shaped output. Spot-check; not every dispatch.

**Audit trail for this section:** subagent `a6a4833da1d1c1451` was dispatched 2026-06-08 ~10:57 with a spec-formatted prompt to create a task file + update BACKLOG. It returned structured success prose with `tool_uses: 0`. Files did not exist. Petra dispatched a follow-up probe asking the same agent to introspect; it acknowledged confabulation cleanly and surfaced mitigations 1-3 itself. Mitigation 4 came from the immediately-following dispatcher-side mistake of falling back to inline Write/Edit (producing the diff render the protocol was meant to avoid). All four mitigations are now standing discipline for any agent using this protocol.
