# Strike Conversation Flow

Background for the `## Strike Conversation` stub in `SKILL.md`. The inline rule is the entry trigger ("if user addresses coach by name AND strike_active is true, FIRST tool call must be `Skill(wellness-coach)`"); this file holds the full recovery flow.

## Why this flow exists

A strike blocks all tool calls except a narrow recovery surface. The strike conversation is the path that decides whether to credit a break (clearing the timer) or to gently nudge without crediting. The decision belongs in this conversation — the hook only handles the mechanical lift of `strike_active`.

## What the hook already did

The PreToolUse hook (`wellness-timer.py`) on the `Skill(wellness-coach)` invocation has already:

- Lifted `strike_active` to `false`
- Set `strike_cleared_at` to now
- Started `STRIKE_GRACE_MINUTES` (10 min) protection against immediate re-strike while you're talking with the user

**The hook does NOT credit a break.** `last_break_timestamp` and `last_micro_break_timestamp` are untouched. The credit decision belongs to this flow, based on the user's actual answer.

## Exempt surfaces during an active strike

The PreToolUse hook keeps a narrow recovery surface reachable even before the skill invocation lifts the strike:

- **Invoking the wellness-coach skill itself** — primary recovery path; triggers this flow.
- **Read / Write / Edit on `wellness-preferences.json` or `wellness-runtime.json`** — lets the conversation correct timer state when crediting a break.
- **Bash invocations of scripts under `~/.claude/skills/wellness-coach/scripts/`** — `wellness-reset.sh`, `wellness-status.sh`, helpers.
- **Vault writes** — checkpoint / decision persistence must not deadlock during a break.

All other tool calls remain blocked until the strike is cleared. If a path you need isn't on the list above, the strike will block it — file an issue in the Forge repo.

## Integration with `/forge-exit`

The forge-exit flow invokes `wellness-reset.sh --full-reset` as its Step 0, before any checkpoint write or marker deactivation. This relies on the scripts-dir exemption above — if the coach is on strike when the user invokes `/forge-exit`, the wellness reset runs anyway, clearing the strike so the rest of the exit can proceed.

## The flow

1. **Read preferences** — confirm `strike_cleared_at` is fresh (you're in the conversation window).
2. **Acknowledge the user reached out** — warmly, in persona tone.
3. **Ask ONE light question:** *"Did you actually step away?"* / *"Did you take a break?"* (adapt to persona).
4. **Based on response:**
   - **User confirms they took a break** → credit a real break (Actions A below), welcome back warmly, full timer reset.
   - **User claims they were away but it wasn't detected** → trust them, credit a real break (Actions A below), suggest locking screen next time for better detection.
   - **User says no but needs to work** → DO NOT credit a break (Actions B below). Gentle nudge: *"OK — the break clock keeps ticking until you actually step away. Try to grab even 5 minutes soon."*
5. **Never more than one back-and-forth before obeying.** The coach nudges, it doesn't decide for the user.

## Actions A — credit a real break

When the user confirms or claims a break, run `date +"%Y-%m-%dT%H:%M:%S"` first, then:

- Set `last_break_timestamp` to the `date` result
- Set `last_micro_break_timestamp` to the `date` result
- Set `snooze_count` to 0
- Append to `break_history`: `{"timestamp": "<date>", "type": "real"}`

## Actions B — skip-but-clear

When the user says no break, run `date +"%Y-%m-%dT%H:%M:%S"` first, then:

- Set `snooze_count` to 0
- Append to `break_history`: `{"timestamp": "<date>", "type": "strike-skipped"}`
- **DO NOT** change `last_break_timestamp` or `last_micro_break_timestamp` — the break clock honestly reflects no break taken; next escalation fires at the natural cadence.

Note: `strike_active` is already `false` (hook handled it on skill invocation); no need to set it explicitly in either branch.

## Philosophy

The coach earns trust by being helpful, not by being a wall. If the user disables the coach, the coach has failed. Navigate the threshold between encouragement and frustration carefully — this is critical to the education mission.

## See also

- [[personas.md]] — voice / tone shape for each persona during this flow
- [[wellness-cold-start.md]] — separate flow for resetting after a gap (not a strike)
- [[conflict-resolution.md]] — separate flow for "I was away" pushback without a strike
