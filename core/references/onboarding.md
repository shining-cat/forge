# Forge First-Run Onboarding

Loaded by the `forge` skill (step 0 of the entry checklist) **only** when `~/.claude/forge.conf` exists but `ONBOARDING_COMPLETE` is `false` or missing. Runs once per machine — after the first successful pass, sets `ONBOARDING_COMPLETE=true` and is never read again.

## Onboarding flow

**Welcome message (Petra voice):**

> Petra: First time at the anvil. Let me show you around.
>
> Forge is a session orchestration layer. It keeps a knowledge vault (decisions, checkpoints, friction log), runs agent roles (Keeper tracks state, Refiner catches mistakes, Reviewer validates plans), and gives you a consistent workflow across sessions.
>
> A few things to set up before we start.

### a) Wellness Coach

Check if wellness files exist but hooks aren't wired:

```bash
# Files present?
test -f ~/.claude/skills/wellness-coach/SKILL.md && echo "FILES_PRESENT" || echo "NO_FILES"

# Hooks already wired?
grep -q 'wellness-timer.py' ~/.claude/settings.json 2>/dev/null && echo "HOOKS_WIRED" || echo "NO_HOOKS"
```

- If `NO_FILES` → skip (install script didn't include them)
- If `FILES_PRESENT` + `HOOKS_WIRED` → already active, skip
- If `FILES_PRESENT` + `NO_HOOKS` → ask:

> Forge includes an optional wellness coach — it tracks your work time and nudges you to take breaks. It has three persona styles, calendar awareness, weather-based outdoor suggestions, and configurable escalation (from gentle nudges to blocking tools until you step away).
>
> One thing to know: the wellness coach fires in every Claude Code window on this machine, not just the Forge one. That's intentional — break time is about you, not which terminal you're in.
>
> Want to activate it? You can always enable or disable it later.

**If yes:**
1. Read `~/.claude/settings.json`
2. Add these permissions if not present. Important syntax notes:
   - **Single `*` does not cross `/`** — use the literal absolute path for multi-segment matches, not `*/.claude/...`
   - **Leading `*` in `Bash(...)` is literal**, not a wildcard — use proper `prefix*` form
   - **Tilde `~` expansion is unverified** for permission rules — add both tilde and absolute forms as belt-and-braces

   Patterns to add (substituting the user's actual home directory):
   - `Bash(~/.claude/skills/wellness-coach/scripts/*)` and `Bash(<HOME>/.claude/skills/wellness-coach/scripts/*)`
   - Where `<HOME>` is the user's actual home directory (e.g. `/Users/<your-username>`)

   Wellness preferences live at `${VAULT_PATH}/_shared/wellness-preferences.json` — covered by the existing vault allowlist, no per-file permission needed.
3. Add these hooks if not present:
   - PreToolUse: `python3 ~/.claude/skills/wellness-coach/hooks/wellness-timer.py` (timeout: 5)
   - Stop: `python3 ~/.claude/skills/wellness-coach/hooks/wellness-timer.py` (timeout: 5) — supplemental tick on assistant turn-end; covers Pattern A workflows where the user is mostly reading agent output and PreToolUse fires too rarely
   - PreCompact: `python3 ~/.claude/skills/wellness-coach/hooks/wellness-precompact.py` (timeout: 5)
4. Write the updated settings.json
5. Update `~/.claude/forge.conf`: set `WELLNESS_ENABLED=true`
6. Tell the user: "Wellness coach activated. It'll offer its own onboarding on your next interaction."

**If no:**
Ask: "Want me to remove the wellness coach files, or keep them in case you change your mind?"
- If remove → delete `~/.claude/skills/wellness-coach/` directory
- If keep → leave files, they're inert without hooks

### b) Verify superpowers

```bash
jq -e '.enabledPlugins | keys[] | select(startswith("superpowers@"))' ~/.claude/settings.json 2>/dev/null
```

- If found → ok, continue
- If not found → warn:
  > "Forge depends on the superpowers plugin for process discipline (brainstorming, TDD, debugging, plans). Install it from https://github.com/obra/superpowers-marketplace and add it to your Claude Code plugins."

Don't block — the user might install it later.

### b-2) Maintainer mode

Ask:

> Forge has two postures: **end-user** (default) and **maintainer**.
>
> In end-user mode, Petra keeps Forge's own machinery out of your face — friction-log writes, INDEX maintenance, decision curation, vault hygiene, internal audits don't get surfaced as actionable threads. You can still do those things if you want; they just don't show up as suggestions.
>
> In maintainer mode, all of that becomes visible. Use this if you're extending Forge itself — adding skills, tuning hooks, reshaping the vault layout.
>
> Which posture? (You can flip it later by editing `MAINTAINER_MODE` in `~/.claude/forge.conf`.)

Default to end-user if the user isn't sure. Then:

- If **end-user**: leave `MAINTAINER_MODE=false` (already the install default) — no write needed.
- If **maintainer**: `set_conf_key MAINTAINER_MODE true` (or hand-edit `~/.claude/forge.conf`).

Don't write anything visible unless the user picked the non-default — keep onboarding tight.

### c) Vault project setup

The vault root was created by the install script. Now set up the project structure for the current environment:

1. Detect the current project (same logic as step 1 in the SKILL entry checklist)
2. Create project directories:
   ```
   {VAULT_PATH}/{ENV}/{PROJECT}/
   {VAULT_PATH}/{ENV}/{PROJECT}/decisions/
   {VAULT_PATH}/{ENV}/{PROJECT}/architecture/
   ```
3. If `{VAULT_PATH}/{ENV}/{PROJECT}/INDEX.md` doesn't exist, create a starter:
   ```markdown
   # {PROJECT} — Index

   ## Active Decisions
   (none yet)

   ## Architecture
   (none yet)
   ```

### d) First work folder

After scaffolding the vault, invite the user to confirm or point to their main work folder:

> Petra: The vault's set up. Now — where does the real work live?
>
> I've detected you're in `{current_directory}`. If that's your project, we're good. Otherwise, point me to the folder you want to track — e.g., `~/projects/my-app`.
>
> You can add more projects anytime by saying "add project" from inside the folder.

If the user provides a different path, re-run step (c) with that path as the project root.

### d-2) Multi-environment pattern (optional but recommended)

If only one project/environment exists in the vault so far AND the user works across distinct contexts (personal projects, client work, employer), recommend separating them into top-level environments. This is opt-in, not gated.

Each environment gets its own:

- **folder root** — e.g. `~/projects/work`, `~/projects/personal`, or any layout you prefer (one root per environment)
- **vault section** — `Vault/{ENV}/{project}/` — one section per environment
- **git identity** — set via `.gitconfig.<env>` files referenced from `~/.gitconfig` with `includeIf "gitdir:..."`. Keeps personal vs work commits attributed to the right email automatically based on the directory you're in

**Why it matters:**
- Commit attribution stays correct across contexts (no more "oops, work email on personal repo")
- Project-level rules can differ per environment (separate `CLAUDE.md`, separate `.gitconfig`)
- Prevents accidental cross-context git pushes

> Petra: Want to set up a second environment now? Or skip — you can add one any time by saying "add environment".

If the user opts in, walk them through creating the second environment folder + vault section. If not, continue to step (e).

This is a recommendation, not a requirement. Don't push if the user dismisses it.

### e) Complete onboarding

Update `~/.claude/forge.conf`: set `ONBOARDING_COMPLETE=true`

> Petra: Forge is ready. Let's get to work.

Then continue to step 1 of the SKILL entry checklist as normal.
