# Marker takeover (cross-session conflict)

Background for the `#### 1a. Check existing marker for cross-session conflict` stub in `forge/SKILL.md` Step 1. The short version is one line — *"if another session's `session_id` is on the marker, decide whether it's alive (prompt the user) or dead (silent takeover)"*. Load this file when Step 1a detects a conflicting `session_id`.

## When this fires

Read the existing `${VAULT_PATH}/_shared/forge-active`. Behavior depends on what's there:

- **Missing / empty / `__pending__` / legacy plain-string** → no conflict, proceed to step 1b.
- **JSON marker with `session_id` matching `$CLAUDE_CODE_SESSION_ID`** → re-entry in same session, proceed to step 1b (will overwrite with fresh marker).
- **JSON marker with a DIFFERENT `session_id`** → potential cross-session conflict — run the staleness check below.

## Staleness check (only when session_id differs)

1. Read the `tmux_pane` field from the existing marker (may be `null` or absent).
2. **Primary signal — tmux pane existence.** If `tmux_pane` is non-null AND tmux is installed:
   - Run: `tmux list-panes -F '#{pane_id}' -a 2>/dev/null | grep -q "^<pane_id>$"`
   - Exit 0 (pane found) → "appears alive"
   - Non-zero (pane gone) → "appears dead"
3. **Fallback signal — marker mtime.** If `tmux_pane` is null/absent, or tmux not installed:
   - Marker mtime within last 12 hours → "appears alive"
   - Older than 12 hours → "appears dead"

## If "appears alive"

Ask the user (use `AskUserQuestion`):

> Question: *"Another Forge session ({short_session_id}, project={existing_project}, started {started_at}) appears to still own the marker. Take over?"*
> Options: *"Take over"* (proceed to step 1b) / *"Cancel"* (stop session entry — do NOT overwrite the marker, do NOT continue the checklist)

## If "appears dead"

Silent takeover — emit a one-line note (no prompt), then continue to step 1b:

> *"(Took over Forge from stale session, last active {age_hours}h ago.)"*

## See also

- `forge/SKILL.md` step 1b — the `__pending__` sentinel write that comes next
- `forge/SKILL.md` step 1c — the JSON marker format
- `references/lifecycle.md` — full session lifecycle
