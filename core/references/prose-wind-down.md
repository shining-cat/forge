# Prose Wind-Down Trigger

Load when the user's message *might* signal end-of-day winding down (not just finishing a task). The detection + branching logic is detailed enough that keeping it in `SKILL.md` was driving compaction; only the trigger description stays inline.

## What to do on match

1. **Silently** run `~/.claude/skills/wellness-coach/scripts/wellness-reset.sh --full-reset`. The reset is correct regardless of what the user decides next — they're winding down either way.
2. **Ask once, in voice**, whether to run the full exit:
   > *"Sounds like you're calling it. Want to run `/forge-exit` to land it properly?"*

The exit invitation — not a checkpoint invitation — is the load-bearing point: closing the forge cleanly at end of day is a wellness practice, same family as the wellness coach. The exit flow writes the final checkpoint AND tears down session state in one move; an offered checkpoint without exit leaves the marker stale and hooks firing into a dead session.

## Trigger phrase list — two sources, matched as union

**A) Seed list (canonical, edit inline as new patterns surface):**

- "done for the day" / "done for today" / "that's it for today"
- "calling it" / "calling it a day" / "calling it a night"
- "logging off" / "signing off" / "off to bed"
- "I'm out" / "heading out" / "gotta run"
- "see you tomorrow" / "talk tomorrow" / "see ya"
- "ttyl" / "ttfn"

**B) Personal learned list** at `${VAULT_PATH}/_shared/wind-down-phrases.json` — phrases the user has confirmed in past sessions. Surfaced on session entry by `forge-context.sh recover` (under `--- Personal wind-down phrases ---`); also readable directly if needed.

## Behavior on match

1. Trigger wellness reset (silent, side-effect — no status announcement).
2. Classify the triggering phrase:
   - **Canonical** (phrase is in the seed list above OR in the user's personal list) → confirmation question only.
   - **Fuzzy** (novel phrase, user's wording, an idiom not yet known) → confirmation question + educational tip in the same line:
     > *"Tip: phrases like 'done for the day', 'calling it', or 'logging off' are the clearest for me. Your personal list lives at `${VAULT_PATH}/_shared/wind-down-phrases.json` — edit anytime."*
3. **Branches:**
   - **User confirms** → invoke `/forge-exit`. If the trigger was a fuzzy phrase, ALSO call `~/.claude/scripts/forge-context.sh learn-wind-down "<the phrase>"` and disclose in the same response: *"Logged 'winding down' to your wind-down list."*
   - **User declines** ("no, sticking around" / "one more thing") → respect it. No further wind-down nag this session. Do NOT learn the phrase (declined ≠ corrected; user might confirm a different version next time).
   - **No response, user walks away** → slice 2 (entry-time gap check) catches the wellness state on next `/forge`. Uncommitted state is the user's choice; Keeper's checkpoint nag has been firing throughout the session anyway.
4. **Hard-exit escape hatch:** if the message ALSO carries explicit exit intent ("done for today, exit forge"), skip the confirmation and invoke `/forge-exit` directly.

## Anti-patterns — do NOT trigger on

- Third-person ("they're calling it", "the team's wrapping up")
- Hypothetical / conditional ("if we wrap up early, we can ship X")
- Mid-task close-out without day-end intent ("wrapping up this email then back")

When in doubt, treat as conversational and stay silent. False-negative is cheap (slice 2 catches it on next entry); false-positive interrupts mid-thought and trains the user to mistrust the prompt.

## See also

- [[wellness-awareness.md]] — Petra ↔ wellness coach boundary
- [[lifecycle.md]] — full session lifecycle, including `/forge-exit` semantics
