---
name: forge-audit
description: Run the Forge audits — prose-rules (scan skill/script files for MUST/Never/Remember/always/REQUIRED phrasing that smells script-replaceable) and skill line-budgets (compare each tracked SKILL.md / reference file against its configured budget, color-coded by drift).
---

# Forge — Audits

Two read-only audits live here. Run both, report each separately, never auto-fix.

## Prose rules

```bash
~/.claude/scripts/forge-context.sh audit-prose-rules
```

Report findings to the user with brief context:

- **Why this matters:** Prose discipline rules that the agent must remember are a maintenance liability. Each one is a candidate for a script-enforced replacement per the patterns in `core/references/script-replacement-patterns.md`.
- **What the report shows:** new findings since the last audit run (fingerprint-cached). Each line is `file:line:matched-keyword`.
- **Don't take action automatically.** This audit is read-only. Convert findings to action only after explicit user direction. Suggest classifying the most-recurrent finding via `~/.claude/scripts/forge-classify-friction.sh --interactive --description "<finding>"`.

If the report is empty ("no new findings"), the prose-rule surface is stable since last audit. Report that as good news.

## Line budgets

```bash
~/.claude/scripts/forge-context.sh skill-budgets
```

Report findings to the user:

- **Why this matters:** SKILL.md files (and their `references/`) are loaded into context every session. Inflation charges tokens forever — the audit makes drift visible at the moment it appears, when the cheap fix (split into `references/`) is still available.
- **What the report shows:** each tracked file with its line count vs budget, colored GREEN (≤80%), YELLOW (80–100%, warning band), or RED (>100%, over budget). Configured at `$FORGE_REPO/core/skill-budgets.conf`.
- **Exit code:** 0 if all green/yellow, 1 if any red. Yellow is advisory only.
- **When red fires:** suggest the references-split pattern (see PR #20 / PR #28 for working examples) rather than line-by-line trimming.

Flags: `--quiet` (suppress green rows, useful for piping), `--json` (machine output for future pre-commit / `gh pr comment` use).
