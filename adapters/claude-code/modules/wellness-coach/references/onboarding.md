# Wellness Coach — Onboarding

Load when the startup check returns `NO_PREFS` (no `wellness-preferences.json` exists), or when the user explicitly asks to redo onboarding. The full flow runs once per machine, then the file isn't needed again.

Auto-triggers when no preferences file exists. Show all 8 questions upfront as a progress card, then ask one at a time.

## Intro message

> I'm your wellness coach! I'll help you take better breaks while you work. Let me set up your preferences — 8 quick questions. You can change any answer at any step, and update your preferences anytime later.
>
> Heads up — I'll fire in every Claude Code window on this machine, even sibling windows that aren't running Forge. That's intentional: break time is about you, not which terminal you're in. If you'd rather I only fire in Forge sessions, file an issue in the Forge repo and we'll reconsider.

## Progress card (show and update after each answer)

```
┌─────────────────────────────────────────────────┐
│  1. Persona style          ○ not answered yet   │
│  2. Micro-break frequency  ○ not answered yet   │
│  3. Real break frequency   ○ not answered yet   │
│  4. Insistence level       ○ not answered yet   │
│  5. Calendar access        ○ not answered yet   │
│  6. Weather & location     ○ not answered yet   │
│  7. Personal notes         ○ not answered yet   │
│  8. Activity monitoring    ○ not answered yet   │
└─────────────────────────────────────────────────┘
```

Mark answered questions with `●` and show the chosen value.

## Questions

### 1. Persona style & name — How should I talk to you?

Present each persona with 3 randomly picked name suggestions (short, punchy, easy to remember). Different names suit different styles:

- `professional` — Factual, concise, no emoji
  Suggested names: e.g., **Cal**, **Pace**, **Rem**
- `playful` — Friendly, encouraging, occasional emoji
  Suggested names: e.g., **Sunny**, **Ziggy**, **Pip**
- `character` — Full personality with catchphrases, dramatic flair
  Suggested names: e.g., **Vigor**, **Rex**, **Bolt**

After picking a persona, the user picks a name from the suggestions. Offer:
- **"Shuffle"** — regenerate 3 new name suggestions for the chosen persona
- **"Custom"** — hint: "Or type your own name if you have one in mind"

Store the chosen name in preferences as `coach_name`. Use this name in ALL persona communication — greetings, reminders, strikes, queries. The name is how the user addresses the coach (e.g., "hey Vigor").

### 2. Micro-break frequency — Short breaks (30s–2min: look away, stretch, blink). How often?

- Every 15 / 20 / 25 minutes, or custom

### 3. Real break frequency — Step away, walk around, 5+ minutes. How often?

- Every 30 / 45 / 60 minutes, or custom

### 4. Insistence level — How persistent should I be?

- `suggest` — Suggest only, never escalate
- `escalating` — Escalate if ignored, but never block tools
- `escalating_strike` — Full escalation, will block tools if break is seriously overdue

### 5. Calendar access — Should I check your calendar to time breaks around meetings?

- Yes (uses Google Calendar plugin if available) / No

If the user picks **Yes**, verify the scope is actually granted *before* writing `calendar_enabled: true` — otherwise the first calendar fetch later in the session fails with a 403 the user has no context to debug.

Probe (silent unless it fails):
```bash
gws calendar +agenda 2>&1 | head -5
```

Branch on the result:
- **Command not found** (`gws: command not found` or similar) → "Calendar awareness needs the Google Workspace plugin. Install it first, then say 'enable calendar awareness' to re-enable. Setting calendar to OFF for now."
- **Output contains `403`, `PERMISSION_DENIED`, `insufficient`, or `invalid_grant`** → "Calendar awareness needs the `https://www.googleapis.com/auth/calendar.readonly` scope on your gws-auth token. Run `/gws-auth` to refresh with that scope, then say 'enable calendar awareness'. Setting calendar to OFF for now."
- **Other error** → surface the first 1-2 lines, set OFF, point to `/gws-auth` as the most common remedy.
- **Success** (events list or "no upcoming events") → set `calendar_enabled: true`.

This keeps the answered-question state honest: `calendar_enabled` is true ONLY when the scope check just passed. Users who opt in but lack the scope get told now, not via a mystery 403 mid-session.

### 6. Weather & location — Should I check weather for outdoor break suggestions?

- Yes + city (e.g., "Oslo, Norway") / No

### 7. Personal notes — Anything I should know? (dog to walk, standing desk, park nearby, physio exercises, etc.)

- Free text, or "nothing for now"

### 8. Activity monitoring — How should I detect breaks?

Present as:

```
Recommended — Activity-aware (default):
   I install a lightweight background service that checks
   your screen state every 60 seconds (~0.1% CPU). When 
   your screen locks or turns off, I automatically credit 
   that as a break — no need to tell me. You can uninstall 
   anytime by saying "uninstall activity monitor".

Alternative — Timing-only:
   I just track time since your last break and detect 
   laptop sleep (lid close). You'll need to tell me when 
   you take a break ("brb", "back", etc.). Locking your 
   screen or stepping away won't be detected — I'll keep 
   counting as if you're working.

Default is Activity-aware. Say "yes" to install (or just 
hit enter), or "timing-only" to skip the daemon.
```

**Tier 2 path (default / explicit "yes"):**

Run the install script:
```bash
~/.claude/skills/wellness-coach/scripts/install-monitor.sh
```

Branch on the outcome:

- **Success (exit 0)** → set `activity_monitor_enabled: true` and `activity_monitor_installed: true`, then show post-install tips (below).

- **Failure (exit non-zero)** → inspect the captured output and pick the matching message:

  - Output contains `C compiler not found` → Xcode Command Line Tools missing.
    > "The activity monitor needs Xcode Command Line Tools to compile the screen-state checker. Run `xcode-select --install` in a terminal (it opens a system dialog and takes a few minutes). Once it's done, say 'install activity monitor' and I'll retry. For now, I'm starting you on timing-only mode."

  - Output contains `python3 not found` → unusual; suggest checking PATH and falling back.
    > "I couldn't find python3 on your PATH, which the sampler needs. Starting you on timing-only mode — once python3 is reachable, say 'install activity monitor' to retry."

  - Output contains `Failed to load LaunchAgent` → launchd issue; the script already cleaned up.
    > "macOS refused to load the background sampler (the script cleaned up the partial install). Starting you on timing-only mode. If you want to retry later, say 'install activity monitor' — and if it still fails, paste the install output and I'll dig in."

  - Anything else → generic compile/install failure.
    > "Activity monitor install failed: <first line or two of the error>. Starting you on timing-only mode — say 'install activity monitor' to retry later."

  In every failure branch, set `activity_monitor_enabled: false` and `activity_monitor_installed: false`, then continue onboarding. Do NOT block the user — the fallback is fully functional.

**Tier 1 path (explicit "timing-only"):**

Set `activity_monitor_enabled: false` and `activity_monitor_installed: false`, continue.

**Post-install tips** — show ONLY after a successful Tier 2 install:

```
Activity monitor installed!

For best results:
• Lock your screen (Ctrl+Cmd+Q) when you step away
• Set display-off timeout to 5–10 min in 
  System Settings → Lock Screen

If anything looks off later, run:
  ~/.claude/skills/wellness-coach/scripts/wellness-status.sh --diagnose
```

## Changing answers

If the user says "change 3" or "go back to 2", update that answer and re-show the card.

## Completing onboarding

After all 8 questions are answered, write the preferences file:

```python
# Build prefs dict from answers, merged with DEFAULT_PREFS
# Run: date +"%Y-%m-%dT%H:%M:%S" to get actual system time
# Set last_break_timestamp and last_micro_break_timestamp to date output
# Write to ${VAULT_PATH}/_shared/wellness-preferences.json
```

Confirm in the chosen persona tone.

## See also

- [[conflict-resolution.md]] — how to handle "I was away" push-back post-onboarding (different message per tier, plus install/uninstall commands)
