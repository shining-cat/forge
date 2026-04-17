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
3. After writing the checkpoint, truncate braindump.md — write just `# Brain Dump\n` as the contents

### 2. Write Checkpoint

**OVERWRITE** `{{VAULT}}/{ENV}/{PROJECT}/current-checkpoint.md` using the template from the Keeper skill.

### 3. Log Any Unlogged Decisions

If decisions were validated during the session but not yet logged:
- Create decision files in `{{VAULT}}/{ENV}/{PROJECT}/decisions/`
- Update INDEX.md

### 4. Confirm

Display:
```
**[Keeper]** Checkpoint saved — {date}
  Branch: {branch}
  Goal: {one-line goal}
  Completed: {count items}
  Next: {first next step}
```
