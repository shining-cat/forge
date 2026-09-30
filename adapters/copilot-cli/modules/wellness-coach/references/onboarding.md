# Wellness Coach — Onboarding

Load when preferences are missing, `wellness_onboarding_complete` is not `true`, or the user explicitly asks to redo onboarding. An existing file from another runtime does not prove that Copilot's questions were answered. Preserve it and offer existing values as suggested answers; never treat them as consent, especially for strikes or activity monitoring.

Auto-triggers when no preferences file exists. Show all 8 questions upfront as a progress card, then ask one at a time.

## Storage consent (before any wellness write or monitor installation)

Resolve and display the proposed full destination: `python3 "${COPILOT_HOME:-$HOME/.copilot}/skills/wellness-coach/hooks/wellness_location.py" propose` (or `propose --directory RELATIVE_SUBPATH` to validate an override). Ask for explicit permission to store wellness answers and generated data there, or for another relative subpath under the configured vault `_shared`. The `directory` subcommand instead reports the **current** location, including legacy flat storage; do not mistake it for the proposed default. Do not write a preference, runtime, cache, log, locator or install the monitor until they agree. Declining leaves setup incomplete and causes no new wellness writes. Never offer a home-directory destination.

If flat legacy `_shared/wellness-preferences.json` exists, explain that it stays intact. **Stop all old Claude/Copilot CLI sessions and both wellness LaunchAgents before cutover**, including old processes with old code loaded; confirm this with the user and complete the migration while old tooling is inactive. No background old writer may run during copy/publish. Run `python3 "${COPILOT_HOME:-$HOME/.copilot}/skills/wellness-coach/hooks/wellness_location.py" prepare --directory wellness-coach --consent --old-tooling-stopped` (replace directory with their approved relative subpath). This copies existing flat wellness files without deleting them, disables onboarding and activity monitoring in the copied preferences until confirmed setup, and atomically publishes the locator last. If old tooling cannot be stopped, keep flat legacy support, do not publish a locator, and defer setup. Restart CLI sessions/reinstall sampler from updated source after cutover; old tooling must remain stopped until then. If the resolver or migration fails, report the error and stop; do not activate the coach. Add `**/wellness-runtime.json`, `**/wellness-runtime.tmp`, `**/wellness-idle-log.json`, `**/wellness-idle-sampler.log`, `**/wellness-calendar-cache.json`, `**/wellness-activity-log.md`, `**/wellness-activity-log.md.trimmed`, `**/wellness-preferences.lock`, `**/wellness-preferences.tmp`, `**/wellness-idle-log.*`, and `**/wellness-runtime.json.*` to the **vault's** `.gitignore` (not here). Track preferences and locator in vault git; if you override `activity_log_path`, ignore that file and its `.trimmed` sidecar as well.

## Intro message

> I'm your wellness coach! I'll help you take better breaks while you work. Let me set up your preferences — 8 quick questions. You can change any answer at any step, and update your preferences anytime later.
>
> Heads up — I'll fire in every GitHub Copilot CLI window on this machine, even sibling windows that aren't running Forge. That's intentional: break time is about you, not which terminal you're in. If you'd rather I only fire in Forge sessions, file an issue in the Forge repo and we'll reconsider.

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
- **Success** (events list or "no upcoming events") → set `calendar_enabled: true` in wellness preferences and `CALENDAR_PROVIDER=gws` in this runtime's `forge.conf`.

This keeps the answered-question state honest: `calendar_enabled` is true ONLY when the scope check just passed. Users who opt in but lack the scope get told now, not via a mystery 403 mid-session. For opt-out, set `calendar_enabled: false` and remove `CALENDAR_PROVIDER` (or leave it unset); `m365` is not yet supported.

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
"${COPILOT_HOME:-$HOME/.copilot}/skills/wellness-coach/scripts/install-monitor.sh"
```

Branch on the outcome:

- **Success (exit 0)** → the binary passed a self-check and the LaunchAgent was registered. Through Keeper, write confirmed setup with `activity_monitor_installed: true`, `activity_monitor_enabled: false` and fresh runtime timestamps, then run `"${COPILOT_HOME:-$HOME/.copilot}/bin/idle-sampler.py"` and verify that the resolved `wellness-idle-log.json` contains a sample from the last minute while the Forge marker is active. Only then use Keeper to set `activity_monitor_enabled: true`. If no sample is produced, report that the sampler is not healthy, leave `activity_monitor_enabled: false`, and continue in timing-only mode. Registration alone is not proof of sampling.

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
  "${COPILOT_HOME:-$HOME/.copilot}/skills/wellness-coach/scripts/wellness-status.sh" --diagnose
```

## Changing answers

If the user says "change 3" or "go back to 2", update that answer and re-show the card.

## Completing onboarding

After all 8 questions are answered, write the preferences through Keeper's authored-vault path and the `preferences.py` split writer. First persist confirmed answers with `wellness_onboarding_complete: false`, `activity_monitor_enabled: false`, and fresh runtime break and reminder timestamps; clear `strike_active` and `strike_cleared_at`. Only after this write succeeds, set `wellness_onboarding_complete: true` in a separate write. This order prevents a stale shared timestamp from causing a strike between preference and runtime file writes. If activity-aware was selected, check a fresh sample after that activation and only then enable it; if sampling fails, leave the activity monitor disabled and use timing-only reminders. If setup is deferred or an answer is missing, leave the flag false and do not start enforcement.

```python
# Build prefs dict from answers, merged with DEFAULT_PREFS
# Run: date +"%Y-%m-%dT%H:%M:%S" to get actual system time
# Set last_break_timestamp and last_micro_break_timestamp to date output
# Persist setup preferences and fresh runtime state using read_modify_write()
```

Confirm in the chosen persona tone.

## See also

- [[conflict-resolution.md]] — how to handle "I was away" push-back post-onboarding (different message per tier, plus install/uninstall commands)
