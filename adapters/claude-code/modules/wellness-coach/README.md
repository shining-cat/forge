# Wellness Coach

A context-aware wellness coaching module for Claude Code, bundled with Forge as an optional opt-in. Unlike blind timers, it uses work context (task boundaries, calendar, weather) and personal knowledge to suggest breaks at the right moments, in the right tone, with escalation up to refusing to work.

## Features

- **Activity-aware break detection** — detects screen lock and display-off as real breaks (default; falls back to timing-only if install fails)
- **Context-aware timing** — suggests breaks based on work rhythm, not arbitrary intervals
- **Calendar integration** — knows when your next meeting is, suggests breaks before them
- **Weather awareness** — outdoor suggestions when weather is nice, indoor alternatives when it's not
- **Three personas** — professional, playful, or full character — switchable anytime
- **Escalating enforcement** — from gentle nudges to refusing to work (configurable)
- **Multi-terminal aware** — coordinated across all Claude Code instances
- **Personal knowledge** — remembers your preferences, habits, and patterns

## Setup

The plugin auto-configures on first use. It will ask 8 quick questions:

1. **Persona style** — professional / playful / full character
2. **Micro-break frequency** — how often to suggest short breaks (30s–2min)
3. **Real break frequency** — how often to suggest stepping away (5+ min)
4. **Insistence level** — suggest only / escalate / full escalation + strike
5. **Calendar access** — integrate with Google Calendar for meeting-aware timing
6. **Weather & location** — check weather for outdoor/indoor break suggestions
7. **Personal notes** — dog to walk, standing desk, park nearby, etc.
8. **Activity monitoring** — activity-aware screen state detection (default) or timing-only fallback

You can update preferences anytime by saying "update wellness preferences".

## Activity Monitoring

The plugin offers two tiers of break detection. **Activity-aware is the default** — onboarding tries to install it automatically, falling back to timing-only if the install can't complete (e.g., Xcode Command Line Tools missing).

### Tier 2: Activity-aware (default)

A lightweight background service checks your screen state every 60 seconds. When your screen locks or turns off, the plugin automatically credits that as a break.

**The trigger is screen state, not user presence.** A break is credited only when the laptop visibly registers you as away — your screen is locked, your display is off, or the system is asleep. **If your screen stays on and unlocked, no break is credited**, even if you're physically not at the keyboard.

This is deliberate: it prevents false-positives from non-terminal activity. A video meeting in a browser, time spent in another app, reading on the same screen — all keep the screen on and unlocked, and none of them are a real break. The monitor stays accurate by trusting the screen state, not by guessing whether you're "really" working.

**What it detects:**
- Screen lock (Ctrl+Cmd+Q or auto-lock)
- Display off (timeout or lid close)
- System sleep

**What it doesn't detect (by design):**
- Walking away without locking (until display-off timeout kicks in)
- Video meetings, browsing, or other apps while screen stays on and unlocked
- Switching focus away from Claude Code without locking

**Practical implication:** if you want a break to count, lock your screen (Ctrl+Cmd+Q) when you step away. Setting a short display-off timeout (5–10 min in System Settings → Lock Screen) is the belt-and-braces — anything you forget to lock will eventually trigger the credit when the display sleeps.

**Tiered classification** — lock duration determines whether the break counts:

| Lock duration | Credited as | Effect |
|---|---|---|
| < 2 min | nothing | noise floor — ignored entirely |
| 2–10 min | micro-break | resets the stretch timer only |
| 10+ min | real break | resets both timers, clears any active strike |

Thresholds are configurable via `micro_break_lock_threshold_minutes` and `real_break_lock_threshold_minutes` in `wellness-preferences.json`. Defaults are tuned so a phone glance doesn't fake a break, and a 7-minute coffee top-up doesn't reset the real-break timer.

**Install:** Attempted by default during onboarding (question 8). Can also be installed anytime by saying "install activity monitor".

**Uninstall:** Say "uninstall activity monitor" or run:
```bash
~/.claude/skills/wellness-coach/scripts/uninstall-monitor.sh
```

**For best results:**
- Lock your screen (Ctrl+Cmd+Q) when you step away
- Set display-off timeout to 5–10 min in System Settings → Lock Screen

**Requirements:** Xcode Command Line Tools (for one-time compilation of the screen state binary). Install with `xcode-select --install` if needed.

**Health check:** If breaks aren't being detected, run the diagnostic to see exactly which component is unhappy:
```bash
~/.claude/skills/wellness-coach/scripts/wellness-status.sh --diagnose
```

### Tier 1: Timing-only (fallback)

Tracks wall-clock time since your last confirmed break and detects laptop sleep (lid close). You need to tell the plugin when you take a break ("brb", "back", etc.). Screen lock and stepping away without closing the lid are **not** detected.

Use this tier if you prefer not to run a background sampler, or if the Tier 2 install can't complete on your machine. You can opt in explicitly by answering "timing-only" to question 8, or be automatically dropped here if the default install hits a blocker.

## Personas

### Professional
Factual, concise, respectful. No emoji, no teasing. Strike mode is firm but impersonal.

### Playful
Friendly, encouraging, occasional emoji. Light teasing when you resist. Strike mode is humorous but firm.

### Character
Has a name and personality. Catchphrases, running jokes, dramatic flair. Strike mode is theatrical.

## Escalation Ladder

1. **Micro-nudge** — in-conversation only, skippable, no notification
2. **Break suggestion** — in-conversation + macOS notification, one snooze allowed
3. **Insistent** — references ignored earlier suggestion, no more snoozes
4. **Strike** — blocks all tool execution until you take a break

Escalation depth is configurable:
- `suggest` — levels 1–2 only
- `escalating` — levels 1–3
- `escalating_strike` — levels 1–4 (default)

## Calendar & Weather

Both are optional. Calendar uses the Google Calendar plugin if available. Weather uses wttr.in (free, no API key needed).

- Nice weather → "17°C and sunny — go for a walk?"
- Bad weather → "Raining — stretch at your desk"
- Meeting in 15 min → "Take your break NOW before the meeting"

## Multi-Terminal

All instances share `${VAULT_PATH}/_shared/wellness-preferences.json`. Break taken in one terminal resets the timer for all. Strike in any terminal blocks all terminals. Break acknowledged anywhere resumes everywhere.

## Configuration

**Master switch — `WELLNESS_ENABLED` in `~/.claude/forge.conf`.** This flag is the single source of truth for the entire coach. It is read strictly: the coach is active **only** when `WELLNESS_ENABLED=true`; any other value — `false`, empty, an absent key, or a missing `forge.conf` — reads as **disabled**, and every enforcement surface becomes a clean no-op (no breaks, no strikes, no blocking, no suggestions, no sampling). Toggle it in conversation ("disable the wellness coach") or by editing `forge.conf`; the change takes effect on the next tool call — no restart needed.

Every consumer honors the flag:

| Consumer | Role | Honors flag |
|----------|------|:--:|
| `hooks/wellness-timer.py` | PreToolUse strike/break + Stop tick | ✅ (gated at top of `main()`) |
| `hooks/wellness-precompact.py` | break suggestion during compaction | ✅ |
| `scripts/idle-sampler.py` | Tier-2 activity sampler (launchd) | ✅ (also marker-gated) |
| `scripts/wellness-reset.sh --if-cold-start` | cold-start reset at session entry | ✅ |

The strict `==true` semantics match `wellness-reset.sh` exactly, via `preferences.is_wellness_enabled()` (the sampler duplicates the read since `scripts/` can't import `hooks/`). Before this was unified, only the cold-start reset honored the flag while enforcement fired regardless — a "disabled" coach could still strike (friction 2026-07-08, 2026-07-10).

State is split across two files in `${VAULT_PATH}/_shared/` (legacy: `~/.claude/` if Forge isn't installed):

- **`wellness-preferences.json`** — setup keys you choose during onboarding (persona, intervals, calendar/weather toggles, notes). Tracked in vault git. Edit directly or via conversation ("set break interval to 90 minutes", "change persona to professional").
- **`wellness-runtime.json`** — runtime keys the coach auto-modifies (`last_break_timestamp`, `last_micro_break_timestamp`, `break_history`, `strike_active`, etc.). **Gitignored** to keep vault commits signal-only. Do not hand-edit unless you know what you're doing — `wellness-reset.sh` exists for safe resets.

The Python code merges both files transparently via `read_prefs()`, so call sites see a single dict. The split is documented in `hooks/preferences.py:55-70` (`RUNTIME_FIELDS` frozenset).

**See the current state at a glance** — instead of grepping both files, run:

```bash
~/.claude/skills/wellness-coach/scripts/wellness-status.sh --state
```

Prints all setup + runtime values, recent break history, and next predicted nag times — the single command for "what's the wellness coach thinking right now?".

## Files

```
wellness-coach/
├── hooks/
│   ├── wellness-timer.py         — main hook (timer, escalation, strike)
│   ├── wellness-precompact.py    — break suggestions during compaction
│   ├── preferences.py            — shared preferences module
│   ├── activity_log.py           — timestamped activity logging
│   ├── formatting.py             — box rendering and terminal centering
│   ├── context.py                — weather, calendar, energy enrichment
│   └── personas.py               — persona message templates
├── skills/wellness-coach/
│   └── SKILL.md                  — onboarding, suggestions, personas
├── scripts/
│   ├── notify.sh                 — macOS notification helper
│   ├── weather.sh                — wttr.in weather helper
│   ├── idle-sampler.py           — background screen state sampler (Tier 2)
│   ├── install-monitor.sh        — Tier 2 install
│   ├── uninstall-monitor.sh      — Tier 2 uninstall
│   └── wellness-reset.sh         — manual strike reset
├── src/
│   └── screen_state.c            — CoreGraphics display + lock checker
└── README.md
```
