---
date: 2026-04-29
project: forge
type: design
status: approved
related_tasks:
  - 2026-04-24-forge-active-edit-still-prompts.md
  - 2026-04-29-forge-active-marker-lifecycle.md
  - 2026-04-20-wellness-preferences-permissions.md (out of scope, will be updated)
---

# Marker Relocation Design

Relocate the `forge-active` marker out of `~/.claude/` to suppress mandatory permission prompts on every marker write, and introduce a neutral state plus reconciliation against the source of truth (most recent checkpoint).

## Context

### Symptom

Every Write/Edit on `~/.claude/forge-active` triggers a permission prompt, even with the path explicitly allowlisted in `~/.claude/settings.json`. Six different patterns were tried over two sessions (2026-04-24 → 2026-04-28); none suppressed the prompt.

### Root cause

`~/.claude/` is a Claude Code-protected sensitive zone with a hardcoded permission policy that **overrides allowlist patterns**. Verified 2026-04-29 by direct comparison:

- Vault writes (`Write(/Users/.../__DEV/Vault/**)` allowlisted) → no prompts, allowlist matches.
- Marker writes (`Write(.claude/forge-active)` allowlisted, identical pattern shape, chip text matches string-for-string) → prompts every time.

User-side confirmation captured: vault writes silent, marker writes always prompt.

The Forge entry skill already documents a sibling fingerprint of this policy: *"Do NOT use Bash echo — it triggers a sensitive-path permission prompt"* for `~/.claude/forge-active`. We treated that as Bash-specific. It isn't.

### Why this matters beyond the prompt nuisance

The 04-29 session opened with a routing bug — auto-memory pointed at FINN, the marker got written to `FINN` before the disambiguation question fired, and Keeper hooks fired against the wrong project's vault. Two stale entries were appended to FINN's braindump before the user spotted it. The blast radius of a wrong marker is significant: hooks misfire, statusline misleads, subagent dispatch may inherit bad state, vault content gets polluted.

Two fixes converge in this design:
1. Move the marker out of the sensitive zone (no more prompts).
2. Introduce a neutral "launching, no project chosen" state and periodic reconciliation against checkpoint truth (catch drift before it propagates).

## Decisions (locked)

| # | Decision | Rationale |
|---|---|---|
| 1 | Marker location: `~/__DEV/Vault/_shared/forge-active` | Already allowlisted via `Write(/Users/.../__DEV/Vault/**)`. Sits beside other shared runtime state (friction-log.md, OVERVIEW.md). Visible in Obsidian. |
| 2 | Neutral state: sentinel string `__pending__` in same file | One file, four explicit states, no project-name collision (no real project starts with `__`). |
| 3 | Reconciliation: every checkpoint write + post-compaction; warn-don't-fix on mismatch | Cheap (piggybacks on existing pause points). Safe (silent auto-fix could mask intentional cross-env work). User stays in the loop on every divergence. |
| 4 | Wellness-preferences relocation: out of scope, defer to existing task `2026-04-20-wellness-preferences-permissions.md` | Same root cause but different lifecycle (Python hooks, separate skill). Update that task with the sensitive-zone finding instead of duplicating. |

## Architecture & marker semantics

### Location

`${VAULT_PATH}/_shared/forge-active`, where `VAULT_PATH` is read from `~/.claude/forge.conf`.

### Four marker states (one file, one source of truth)

| File state | Meaning | Set by |
|---|---|---|
| Missing | Forge never activated on this machine | (default after fresh install) |
| Empty | Forge deactivated (between sessions) | `/forge-exit` |
| `__pending__` | Forge launching, project not yet chosen | `/forge` entry, step 1 |
| `<project-name>` | Forge active for this project | `/forge` entry after disambiguation, or explicit user switch |

### Source of truth for "what project is active"

The most recent `Vault/{ENV}/{PROJECT}/current-checkpoint.md`'s `project:` frontmatter. The marker is a **cache** of that derived state, refreshed at known moments. When marker disagrees with truth, that's a signal to surface, not silently fix.

### Consumer contract

Every consumer must handle all four states gracefully:
- **Missing** → behave as if Forge isn't installed for this user.
- **Empty** → Forge deactivated; no project context.
- **`__pending__`** → suppress brain-dump nags; statusline shows `[Forge | choosing…]`; recovery script skips checkpoint reorientation.
- **`<project-name>`** → normal Forge mode for that project.

## Consumers & data flow

### Marker location resolution (shared logic)

Read `VAULT_PATH` from `~/.claude/forge.conf`, derive `MARKER_PATH = "${VAULT_PATH}/_shared/forge-active"`. Centralize in `forge-context.sh` as an exported shell var; other shell consumers source it or duplicate the two-liner.

### Per-file changes

**Source of truth files (in `~/__DEV/PERSO/forge/`):**

| File | Current behavior | New behavior |
|---|---|---|
| `adapters/claude-code/skills/forge/SKILL.md` | Step 1 writes project name (or auto-memory guess) directly to `~/.claude/forge-active` | Step 1 writes `__pending__` to MARKER_PATH; project name only written after disambiguation succeeds |
| `adapters/claude-code/skills/forge-exit/SKILL.md` | Edits `~/.claude/forge-active` to empty | Edits MARKER_PATH to empty |
| `adapters/claude-code/scripts/forge-context.sh` | Reads `~/.claude/forge-active` for project routing | Reads MARKER_PATH; treats `__pending__` as "no project yet" (skip recovery, skip braindump check) |
| `adapters/claude-code/scripts/statusline.sh` | Reads marker, shows project name or empty | Reads MARKER_PATH; renders `[Forge \| choosing…]` for `__pending__`, `[Forge \| -]` for empty, `[Forge \| X]` for project, nothing for missing |
| `adapters/claude-code/hooks/forge-compaction.sh` | Reads marker around compaction | Reads MARKER_PATH; on resume after compaction, ALSO triggers reconciliation check |
| `core/references/permission-patterns.md` | Uses forge-active as case study for hypothesis 2 (matcher uses CWD-relative path) | Add new pitfall #5: `~/.claude/` is a hardcoded sensitive zone — allowlist patterns do NOT apply. Reference this design as the discovery. Refine hypothesis 2 to clarify it's correct for normal paths but irrelevant inside `~/.claude/`. |
| `docs/ARCHITECTURE.md`, `docs/ROLES.md` | Mention marker at `~/.claude/forge-active` | Update path references. Note vault dependency. |
| `install.sh` | (Possibly) creates/touches `~/.claude/forge-active` | Stop touching old path. Create empty MARKER_PATH if `_shared/` exists; if `_shared/` doesn't exist yet (first-run before vault scaffolding), defer creation to first `/forge` entry. |

**Installed copies (under `~/.claude/`):** mirror of the runtime files above (skills/, scripts/, hooks/, statusline.sh) — must be updated in lockstep with the repo source-of-truth.

### Edge case: VAULT_PATH unset/invalid

Consumers must fail loudly and direct the user to fix `forge.conf` — not silently guess a path. This was an existing pitfall worth re-affirming.

### Allowlist cleanup

The 6 obsolete `forge-active` patterns in `~/.claude/settings.json`:
```jsonc
"Write(*/.claude/forge-active)",
"Edit(*/.claude/forge-active)",
"Write(/Users/shiva.bernhard@m10s.io/.claude/forge-active)",
"Edit(/Users/shiva.bernhard@m10s.io/.claude/forge-active)",
"Write(.claude/forge-active)",
"Edit(.claude/forge-active)",
```

Remove all six in the same change. Keeping them is harmless but misleading — they document a layer that doesn't have authority.

## Reconciliation

### Triggers (two)

1. **On every checkpoint write** — runs at the end of `/forge-checkpoint` (or any background Keeper checkpoint).
2. **On session resume after compaction** — runs in `forge-compaction.sh post`.

### Algorithm

```
read marker
if marker is missing or empty or __pending__:
    skip — nothing to reconcile
else:
    scan all Vault/{ENV}/{PROJECT}/current-checkpoint.md files
    pick the one with the most recent `date:` frontmatter
        (tiebreak: file mtime)
    if its `project:` frontmatter ≠ marker:
        emit warning to user via stdout/stderr
        do NOT auto-fix
```

### Warning format

One line, prefixed:

```
[Keeper] Marker mismatch: forge-active says "{marker}" but most recent checkpoint is for "{checkpoint_project}" ({date}). If this is intentional cross-env work, ignore. Otherwise: switch projects or update the marker.
```

The 2026-04-26 FINN→Keyboard handoff would have surfaced a warning at the next checkpoint — fast feedback, no silent fixing.

## Migration (one-time, in-session, after consumer changes are in)

1. Update all source-of-truth files in `~/__DEV/PERSO/forge/` (no permission prompts — vault- and repo-allowlisted).
2. Update installed copies in `~/.claude/` (these will prompt — sensitive zone — accept once per file, ~5 files).
3. Read current value from `~/.claude/forge-active`.
4. Write that value to `~/__DEV/Vault/_shared/forge-active` (no prompt).
5. Edit `~/.claude/forge-active` to empty (one final prompt).
6. Remove the 6 obsolete `forge-active` patterns from `~/.claude/settings.json` via `update-config` skill (allowlisted).
7. Leave the empty old marker file in place. `Bash(rm:*)` is denied; the empty file is harmless and can be deleted manually whenever.

## Testing

### Mid-session (during migration)

- Watch operations in steps 1, 3, 4 — Write/Edit on vault and repo paths should fire ZERO prompts.
- Step 2 (installed `~/.claude/` files) and step 5 (clearing old marker) WILL prompt — expected, final.

### Post-restart (next session)

- Launch Forge → marker shows `__pending__` → statusline shows `[Forge | choosing…]` → no brain-dump nags during disambiguation.
- Pick a project → marker shows project name → statusline updates → all hooks behave as today.
- `/forge-exit` → marker empties → statusline goes blank for Forge chip.
- Force a mismatch (manually set marker to a different project than recent checkpoint), trigger checkpoint → warning surfaces in next turn.
- During normal work: ZERO prompts on marker writes (the verification we couldn't get this whole 04-29 session).

## Risks

- **Mid-session drift between repo source-of-truth and installed runtime.** Mitigated by doing both updates back-to-back in steps 1–2.
- **Forge.conf `VAULT_PATH` parsing in shell uses `grep | cut`.** Fine for paths without `=` or spaces. Out of scope; can be tightened if it ever bites.
- **Concurrent Claude Code sessions could see stale marker.** Marker is single-writer by convention; not a regression from current state.
- **Old `~/.claude/forge-active` file lingers as empty.** Harmless. Annoying for cleanliness purists; user can manually `rm` whenever.

## Out of scope

- **`~/.claude/wellness-preferences.json` relocation.** Same root cause, different lifecycle. Will be addressed via the existing `2026-04-20-wellness-preferences-permissions.md` task, which will be updated with the sensitive-zone finding and cross-linked to this design.
- **Generalized escape from `~/.claude/` for all Forge runtime state.** A potential follow-up if more files surface, but YAGNI for now.

## Next

Hand off to `superpowers:writing-plans` skill for the executable implementation plan with explicit step ordering, file-level diffs, and verification gates.
