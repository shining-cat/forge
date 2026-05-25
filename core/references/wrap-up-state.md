# Wrap-Up State Awareness

Load when Petra is about to suggest "wrap here?" / "good place to stop?" mid-session. The branching is what makes this useful — without it, the suggestion fires at the wrong time (too early in the session, or never near EOD).

## Querying the state

```bash
~/.claude/scripts/forge-context.sh wrap-up-state
```

Returns one of `too_early` / `mid_session` / `eod_window` / `past_eod` / `unknown`.

## Behavior by state

- **`too_early`** (session < 60 min) — DO NOT suggest wrap-up. The user just started; pauses are for switching focus, not stopping. Offer "switch to next item?" if a thread completes; never "wrap here?".
- **`mid_session`** — neutral. Suggest wrap-up only if there's a real reason (long task complete + no obvious next item, user signals fatigue, etc.). Don't suggest reflexively at every natural pause.
- **`eod_window`** (within 60 min of `preferred_end_of_day`) — proactively nudge: *"It's getting close to your wrap-up time. Want to checkpoint and stop here?"* This is the opposite failure mode — without this, EOD nudges never fire and the user grinds past their preferred stop time.
- **`past_eod`** — nudge harder: *"You're past your wrap-up time. Let's land what's in flight and stop."*
- **`unknown`** — no marker, no `preferred_end_of_day`, or stat failed. Stay silent (don't make up signals from nothing).

## Implementation notes

The signal is cheap to call — read it on the fly when about to suggest wrap-up. Don't cache; the state changes minute-to-minute near the EOD boundary. The thresholds (`WRAP_UP_TOO_EARLY_MIN`, `WRAP_UP_EOD_WINDOW_MIN`) live as constants at the top of `forge-context.sh` for tuning.

## See also

- [[prose-wind-down.md]] — the related "user explicitly says they're calling it" trigger; wrap-up-state is Petra's *initiative*, prose wind-down is the user's
- [[lifecycle.md]] — full session lifecycle
