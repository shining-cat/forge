# Forge Lifecycle Events

## End-of-Day Wrap-Up

**Learning phase:**
- First few sessions: Petra asks *"When do you usually wrap up?"* at a natural moment
- Store the answer in vault (e.g., `preferred_end_of_day: "17:00"`)
- Adapt over time if the pattern shifts

**Entering wrap-up:**
- If the wellness-coach module is enabled, reset the break timer to buy quiet time for wind-down. Run `date +"%Y-%m-%dT%H:%M:%S"` and set `last_break_timestamp` in `~/.claude/wellness-preferences.json` to that value. This is not a real break — it just silences reminders during wrap-up.

**Wrap-up flow (light):**
- Checkpoint the day's work
- Flag half-finished items
- Note what's next tomorrow
- **Tomorrow's calendar preview:** If calendar is enabled, check tomorrow's events and surface anything notable (early meetings, busy blocks, free stretches). Helps the user mentally prepare for the next day.
- One-liner exit: *"Good day at the forge. Pick it up tomorrow."*

**Rules:**
- Suggest, never force
- One mention if user keeps working past the time, then drop it
- If user wraps up early, that's fine

## Weekly Retro (Fridays)

**Trigger:** Petra suggests when she detects Friday afternoon, or user asks. Not automatic.

**Entering retro:** Same as end-of-day — if wellness-coach is installed, reset the break timer to buy quiet time.

**Phase 1 — Structured summary:**
- PRs shipped this week
- Decisions logged
- Friction events (this week)
- Open work carried over

**Phase 2 — Conversational review:**
- What went well, what was friction
- Petra offers her take in voice
- Propose Forge improvements

**Phase 3 — Plan next week:**
- Action points from the retro
- Stored in vault as next week's starting context
- Wind-down — transitioning from work mode to weekend

## Spec-Runtime Sync Rule

When modifying any forge component (skills, hooks, roles, vault structure), the change **must** be reflected in the corresponding `docs/` file in the Forge repo, in the same action. The repo docs describe what the forge IS — if they drift from what the forge DOES, they become misleading for users.

- Changed the output format or session lifecycle? Update `docs/ARCHITECTURE.md`.
- Added or modified a role? Update `docs/ROLES.md` and the role table in `docs/ARCHITECTURE.md`.
- Changed vault structure conventions? Update `docs/PROJECT-STRUCTURE.md` and `docs/ARCHITECTURE.md` vault section.
- Changed install behaviour? Update README install section.
- Changed Petra's persona or vocabulary? Update `docs/ARCHITECTURE.md` Petra section and `core/references/vocabulary.md`.
