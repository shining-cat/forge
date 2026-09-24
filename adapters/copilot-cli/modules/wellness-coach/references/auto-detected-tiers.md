# Auto-Detected Break Tiers (Tier 2)

Background for the `## Auto-Detected Break Tiers` stub in `SKILL.md`. The hook (`wellness-timer.py`) drives this automatically when the activity monitor is enabled — this file explains the tier system so the coach can answer user questions about it correctly.

## The trigger is screen state

A break is credited only when the laptop visibly registers the user as away — **screen locked, display off, or system asleep**. If the screen stays on and unlocked, no break is credited, even if the user is in a video meeting, browsing another app, or otherwise not in the terminal.

This is deliberate: it prevents false-positives from non-terminal activity. If a user complains *"I was in a meeting and you still nagged me,"* that's the expected behavior — lock the screen to count.

## The three tiers

| Lock duration | Action | Strike cleared? | `break_history` type |
|---|---|---|---|
| < 2 min | ignored (noise floor) | no | not logged |
| 2–10 min | resets 🙆 only | no | `auto-micro` |
| 10+ min | resets 🙆 + ☕ | yes | `auto-real` |

Thresholds are configurable via `micro_break_lock_threshold_minutes` and `real_break_lock_threshold_minutes` in prefs. Defaults: **2 and 10** — designed so a phone glance doesn't count and a 7-min coffee top-up doesn't fake a real break.

## System sleep / reboot

System sleep / reboot is always treated as a real break (uses the real-break threshold as its gap floor).

## Welcome-back is the hook's job

When the user returns from an auto-detected break, the hook shows a tier-appropriate welcome-back message. **Don't add your own welcome-back on top** — the hook already handled it.

## See also

- `scripts/idle-sampler.py` — the daemon that samples screen state (gated on Forge-active marker since 2026-06-05)
- [[wellness-cold-start.md]] — gap-handling on cold session start
- [[conflict-resolution.md]] — what to do when the user contests a detection
