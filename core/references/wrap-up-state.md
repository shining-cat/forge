# Wrap-Up State Awareness

Load when Petra is about to suggest "wrap here?" / "good place to stop?" mid-session. The branching is what makes this useful — without it, the suggestion fires at the wrong time (too early in the session, or never near EOD).

## Querying the state

```bash
~/.claude/scripts/forge-context.sh wrap-up-state
```

Returns one of `too_early` / `mid_session` / `eod_window` / `past_eod` / `eow_window` / `past_eow` / `unknown`.

## Behavior by state

- **`too_early`** (session < 60 min) — DO NOT suggest wrap-up. The user just started; pauses are for switching focus, not stopping. Offer "switch to next item?" if a thread completes; never "wrap here?".
- **`mid_session`** — neutral. Suggest wrap-up only if there's a real reason (long task complete + no obvious next item, user signals fatigue, etc.). Don't suggest reflexively at every natural pause.
- **`eod_window`** (within 60 min of `preferred_end_of_day`) — proactively nudge: *"It's getting close to your wrap-up time. Want to checkpoint and stop here?"* This is the opposite failure mode — without this, EOD nudges never fire and the user grinds past their preferred stop time.
- **`past_eod`** — nudge harder: *"You're past your wrap-up time. Let's land what's in flight and stop."*
- **`eow_window`** (EOW_DAY + within 60 min of `preferred_end_of_day`) — same wrap-up nudge as `eod_window` PLUS trigger weekly-wrap behavior: offer a weekly retro, surface the week's friction events and shipped PRs, suggest BACKLOG triage for next week.
- **`past_eow`** (EOW_DAY + past `preferred_end_of_day`) — same harder nudge as `past_eod` PLUS the weekly-wrap surface above.
- **`unknown`** — no marker, no `preferred_end_of_day`, or stat failed. Stay silent (don't make up signals from nothing).

The EOW states are **strictly stronger** than their EOD counterparts: callers that only care about end-of-day behavior can dispatch `eow_window` → same handler as `eod_window` (and `past_eow` → same as `past_eod`) without missing the daily-wrap signal. Callers wanting the weekly surface dispatch on the `eow_*` variants specifically.

## Chaining with `next-meeting`

At any wrap-up moment, Petra ALSO reads `next-meeting` so the pacing decision accounts for imminent calendar interruptions:

```bash
~/.claude/scripts/forge-context.sh wrap-up-state
~/.claude/scripts/forge-context.sh next-meeting
```

`next-meeting` returns a single line `HH:MM|title|minutes_until` when a meeting starts within `MEETING_WINDOW_MIN` (default 30, configurable in `forge.conf`), or no output when nothing is imminent. This lets Petra say *"EOD in 20 min, but standup in 8 — let's land the diff first, then checkpoint after standup"* instead of suggesting wrap-up that collides with a meeting the user is about to walk into.

Silent output is silent — no fallback prose, no "calendar disabled" chatter unless the user asks.

## Implementation notes

The signal is cheap to call — read it on the fly when about to suggest wrap-up. Don't cache; the state changes minute-to-minute near the EOD boundary. The thresholds (`WRAP_UP_TOO_EARLY_MIN`, `WRAP_UP_EOD_WINDOW_MIN`) live as constants at the top of `forge-context.sh` for tuning. `EOW_DAY` and `MEETING_WINDOW_MIN` are loaded from `forge.conf` (defaults 5 / 30).

## See also

- [[prose-wind-down.md]] — the related "user explicitly says they're calling it" trigger; wrap-up-state is Petra's *initiative*, prose wind-down is the user's
- [[lifecycle.md]] — full session lifecycle
