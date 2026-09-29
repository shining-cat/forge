---
name: forge-checkpoint
description: Use mid-session to save current state to the vault. Invoke with /forge-checkpoint or when a natural pause point is reached during Forge mode.
---

# Forge Checkpoint

Saves the current session state to the vault. Can be invoked explicitly or triggered proactively by Keeper behavior.

**Announce:** "**[Keeper]** Writing checkpoint."

## Steps

### 1. Gather Current State

Collect from the session context and git:

- Current branch: `git -C {project_path} branch --show-current`
- Git status: `git -C {project_path} status --short`
- Recent commits on branch: `git -C {project_path} log --oneline -10`
- Active PRs if known
- Current goal (from conversation context)
- What's completed since last checkpoint
- What's in progress
- What's next
- Any active decisions made this session
- Any approaches ruled out

### 1b. Fold Brain Dump

If `{{VAULT}}/{ENV}/{PROJECT}/braindump.md` exists and has content beyond the header:
1. Read it
2. Incorporate relevant entries into the checkpoint's "Completed" / "In progress" / "Notes" sections
3. After Keeper writes and reads back the checkpoint, have Keeper truncate braindump.md to `# Brain Dump\n`. If the checkpoint write or verification fails, preserve the braindump and report the failure.

### 2. Write Checkpoint

Dispatch Keeper synchronously to **OVERWRITE** `{{VAULT}}/{ENV}/{PROJECT}/current-checkpoint.md` using the template from the Keeper skill, then verify the result. Provide the gathered state and braindump entries. If Keeper cannot complete or verify the write, report/defer it; do not write it inline or truncate the braindump.

### 3. Log Any Unlogged Decisions

If the checkpoint was verified and decisions were validated during the session but not yet logged:
- Have Keeper create decision files in `{{VAULT}}/{ENV}/{PROJECT}/decisions/`
- Have Keeper update INDEX.md and verify both writes

### 4. Confirm

Only after Keeper verifies the checkpoint, display:
```
**[Keeper]** Checkpoint saved — {date}
  Branch: {branch}
  Goal: {one-line goal}
  Completed: {count items}
  Next: {first next step}
```

### 5. Reconcile marker (silent unless mismatch)

After writing the checkpoint, run:
`~/.claude/scripts/forge-context.sh reconcile-marker`

This compares the marker against the most-recent-checkpoint truth. If they disagree, a `[Keeper]` warning surfaces to stderr — repeat it to the user verbatim and let them decide what to do. **Do NOT auto-fix.**

The reconciliation skips silently when the marker is missing, empty, or `__pending__`.
