---
name: forge-audit
description: Run the Forge friction-framework prose-rules audit. Scans Forge skill/script files for prose patterns that smell script-replaceable (MUST/Never/Remember/always/REQUIRED), cross-references friction-log for recurrence, and reports new findings since last run.
---

# Forge — Audit Prose Rules

Run the audit:

```bash
~/.claude/scripts/forge-context.sh audit-prose-rules
```

Report findings to the user with brief context:

- **Why this matters:** Prose discipline rules that the agent must remember are a maintenance liability. Each one is a candidate for a script-enforced replacement per the patterns in `core/references/script-replacement-patterns.md`.
- **What the report shows:** new findings since the last audit run (fingerprint-cached). Each line is `file:line:matched-keyword`.
- **Don't take action automatically.** This audit is read-only. Convert findings to action only after explicit user direction. Suggest classifying the most-recurrent finding via `~/.claude/scripts/forge-classify-friction.sh --interactive --description "<finding>"`.

If the report is empty ("no new findings"), the prose-rule surface is stable since last audit. Report that as good news.
