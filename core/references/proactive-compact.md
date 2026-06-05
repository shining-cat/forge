# Proactive `/compact` discipline

Background for the `**Proactive /compact discipline.**` stub in `forge/SKILL.md` Step 7. The short version is one line — *"on every checkpoint write, invoke `forge-cost-snapshot.sh --json` and append a `/compact` nudge if the snapshot says so"*. Load this file when implementing checkpoint writes or debugging the nag behavior.

## Why this exists

Claude Code's auto-compaction is silently unreliable in long sessions ([anthropics/claude-code#31828](https://github.com/anthropics/claude-code/issues/31828)) — `cache_read` can climb past 900K with no event firing, and the in-app `%` indicator measures against the 200K window not Opus's effective 1M, so what you see isn't what compaction gates on. **Honest measurement instead of trusting the indicator.**

## The rule

- **On every checkpoint write**, invoke `~/.claude/scripts/forge-cost-snapshot.sh --json` and parse the result.
- When `suggest_compact: true`, append one line to the checkpoint body, immediately above the `_Session closed/checkpoint at ...` footer (or at the bottom if no footer):

  > *"cost-snapshot: `<content_kb_total>` KB content, cache_read `<cache_read_current/1000>`K climbing → consider `/compact` to reset window before continuing."*

- When `suggest_compact: false`, no addition — no noise on healthy sessions.

## Trigger semantics

`cache_read > 500K` AND no `≥10%` turn-to-turn drop in the last 20 assistant turns (a drop indicates compaction fired). First-pass thresholds; tune empirically over time.

## Ad-hoc invocation

CLI also invokable ad-hoc by the user or Petra at any moment, not just checkpoint time:

```bash
! ~/.claude/scripts/forge-cost-snapshot.sh
```

(human-readable form when omitting `--json`).
