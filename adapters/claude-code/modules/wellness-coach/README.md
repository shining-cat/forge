# Wellness Coach

A context-aware wellness coaching module for Claude Code, bundled with Forge as an optional opt-in. Unlike blind timers, it uses work context (task boundaries, calendar, weather) and personal knowledge to suggest breaks at the right moments, in the right tone, with escalation up to refusing to work.

## Features

- **Activity-aware break detection** — detects screen lock and display-off as real breaks (optional Tier 2)
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
8. **Activity monitoring** — basic (wall-clock) or activity-aware (screen state detection)

You can update preferences anytime by saying "update wellness preferences".

## Activity Monitoring

The plugin offers two tiers of break detection:

### Tier 1: Basic (default, no setup)

Tracks wall-clock time since your last confirmed break and detects laptop sleep (lid close). You need to tell the plugin when you take a break ("brb", "back", etc.). Screen lock and stepping away without closing the lid are **not** detected.

### Tier 2: Activity-aware (optional install)

A lightweight background service checks your screen state every 60 seconds. When your screen locks or turns off, the plugin automatically credits that as a break.

**What it detects:**
- Screen lock (Ctrl+Cmd+Q or auto-lock)
- Display off (timeout or lid close)
- System sleep

**What it doesn't detect:**
- Walking away without locking (until display-off timeout kicks in)
- Switching to another app while screen stays on (correctly — that's still screen time)

**Install:** During onboarding (question 8) or anytime by saying "install activity monitor"

**Uninstall:** Say "uninstall activity monitor" or run:
```bash
~/.claude/skills/wellness-coach/scripts/uninstall-monitor.sh
```

**For best results (Tier 2):**
- Lock your screen (Ctrl+Cmd+Q) when you step away
- Set display-off timeout to 5–10 min in System Settings → Lock Screen

**Requirements:** Xcode Command Line Tools (for one-time compilation of the screen state binary). Install with `xcode-select --install` if needed.

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

All instances share `~/.claude/wellness-preferences.json`. Break taken in one terminal resets the timer for all. Strike in any terminal blocks all terminals. Break acknowledged anywhere resumes everywhere.

## Configuration

Preferences stored at `~/.claude/wellness-preferences.json`. Editable directly or via conversation ("set break interval to 90 minutes", "change persona to professional").

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
