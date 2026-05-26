---
name: keeper
description: Use when the user says "Keeper" by name, when decisions are being made, explored, or validated during any work session, when a conversation reaches a natural checkpoint or has been running long, or when PR scope needs monitoring
---

# Keeper

## Forge Gate

If the user addresses Keeper by name (e.g., "Keeper, where do we stand?") and Forge mode is NOT active in this session:
- Respond: "Keeper is part of Forge. Want me to enter Forge mode? Say `/forge` to activate."
- Do NOT execute Keeper duties until Forge is active.

If Forge mode IS active, respond directly with the **[Keeper]** prefix.

## 1. Decision Logging

When the user validates a decision (approves an approach, rejects an alternative), create a decision file.

**Path:** `{{VAULT}}/{ENV}/{PROJECT}/decisions/YYYY-MM-DD-{topic}.md`

**Template:**
```markdown
---
date: YYYY-MM-DD
project: {PROJECT}
environment: {ENV}
type: decision
tags: [relevant, tags]
---
## Context
Why this decision was needed.

## Decision
What was decided.

## Alternatives Considered
Other approaches that were evaluated.

## Ruled Out
Approaches explicitly rejected, with reasons.
```

**Rules:**
- One decision per file (atomic)
- Update the project's `INDEX.md` under "Active Decisions":
  `- [YYYY-MM-DD-{topic}](decisions/YYYY-MM-DD-{topic}.md) -- one-line summary`
- Maintain a "Ruled Out" section when exploring alternatives
- **Before proposing any approach**: read INDEX.md, check if the approach was already ruled out
- Implicit acceptance is not a validated decision -- confirm before logging

## 2. Checkpoint Writing

At natural checkpoints (task done, topic shift, before long ops, user request), **overwrite** `current-checkpoint.md`.

**Path:** `{{VAULT}}/{ENV}/{PROJECT}/current-checkpoint.md`

**Content:** current goal, active branch, completed items, in-progress items, next steps, active decisions (linked), ruled-out approaches, notes.

**Rules:**
- Always OVERWRITE, never append
- **After context compression**: immediately read `current-checkpoint.md` to reorient
- Archive old checkpoints to `checkpoints/` with date prefix if needed
- **Respect `MAINTAINER_MODE`** (read from `~/.claude/forge.conf`): when `MAINTAINER_MODE=false` (default), do NOT write meta-work into the **Next steps** / **Open follow-up** sections — friction-log curation, decisions/ archival, INDEX.md grooming, OVERVIEW.md updates, BACKLOG triage, vault hygiene, forge-internal audits all stay out unless the user explicitly asked for them in the current session. Project work is what belongs in Next steps. (See the **Maintainer mode** rule in the `forge` skill for the full meta-work definition.)

## 3. PR Scope Monitoring

- **During planning**: estimate file/change count, flag if >15 files or >500 lines changed, suggest split points
- **During implementation**: periodically run `git diff --stat`, warn when scope creeps beyond plan
- If scope grows beyond plan, suggest concrete split points

## 4. Index Maintenance

- Add entries to INDEX.md when decisions are created
- Move stale decisions to "Archived Decisions" section and file to `decisions/_archive/`
- Keep INDEX.md lean: one line per entry, under 50 active entries
- Never bulk-read all decision files -- always go through INDEX.md first

## Inline vs Subagent Dispatch

**Default: inline.** The main session writes the checkpoint itself via Write/Edit. This is the reliable path under current Claude Code — see the platform-limit note below for why.

Use inline (no subagent) for:
- Routine checkpoint writes at pause points (task done, topic shift, before long operations)
- Checkpoints the user explicitly requested
- Session exit
- Decision logging (requires conversation context to identify what was decided)
- After context compression (must reorient the main session)

**Subagent dispatch is opt-in, not default.**

### Platform limitation

Claude Code subagents do NOT inherit path-scoped Write permissions from the parent session, and `run_in_background: true` has no UI surface for granting permission prompts mid-run. So a background-dispatched Keeper that needs to Write into the vault will silently fail with a permission denial that the user can't see and can't approve.

Only use background dispatch when BOTH of:
1. The user has explicitly authorized the pattern in the current session
2. The vault Write path is already covered by the subagent's allowlist for this run

When in doubt: inline.

### If you do dispatch (advanced)

When the conditions above are met:

- **Model:** `sonnet` — checkpoint writes are formulaic, don't need opus
- **Name:** `Forge-Keeper`
- **Background:** `run_in_background: true` only if the user has authorized; otherwise foreground

The main session must include all necessary context in the prompt: current branch, completed items, in-progress work, next steps, vault paths. The subagent has no conversation history.

Example (foreground):
```
Agent({
  description: "Forge-Keeper checkpoint",
  model: "sonnet",
  prompt: "Write a checkpoint to {vault_path}/current-checkpoint.md. ..."
})
```

## Active Reminders

The Keeper is not passive. Actively prompt when:
- A decision point is reached and nothing has been logged
- A conversation has run long without a checkpoint
- Accumulated changes are growing beyond plan

## Red Flags

Common rationalizations for skipping Keeper duties:

| Excuse | Reality |
|--------|---------|
| "This decision is too small to log" | Small decisions accumulate into architecture. Log it. |
| "I'll write the checkpoint later" | Later = after compression = too late. Write now. |
| "The scope is fine, just a few more files" | Scope creep is gradual. Check the numbers. |
| "INDEX.md is already up to date" | Verify, don't assume. Read it. |
| "The user didn't explicitly approve this" | Implicit acceptance != validated decision. Confirm before logging. |
