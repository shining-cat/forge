# Marker Relocation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Relocate the `forge-active` marker from `~/.claude/forge-active` (sensitive zone, mandatory prompts) to `${VAULT_PATH}/_shared/forge-active` (allowlisted), introduce a `__pending__` neutral state, and add reconciliation against the most-recent-checkpoint truth.

**Architecture:** Centralize marker path resolution in `forge-context.sh`; consumers source it or duplicate the two-liner. Reconciliation runs at every checkpoint write and after compaction; warns on mismatch, never auto-fixes. Skill files write `__pending__` on entry, real project name after disambiguation. Old marker location is left empty in place (`Bash(rm:*)` is denied; harmless).

**Tech Stack:** Bash, Markdown skill files, JSON (`forge.conf` + `settings.json`), no formal test framework — verification via direct script invocation.

**Reference:** Design doc at `.claude/plans/2026-04-29-marker-relocation-design.md` (committed `360c176`).

---

## Phase 1 — Repo: shared resolver + reconciliation function

### Task 1: Add MARKER_PATH resolver to `forge-context.sh`

**Files:**
- Modify: `adapters/claude-code/scripts/forge-context.sh:9`

**Step 1: Read current file to confirm state**

Run: `grep -n "MARKER\|VAULT_PATH" /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge/adapters/claude-code/scripts/forge-context.sh`

Expected: line 9 shows `MARKER="$HOME_DIR/.claude/forge-active"`. May or may not show existing VAULT_PATH parsing.

**Step 2: Replace with resolver**

Replace line 9's hardcoded MARKER with a resolver that reads `VAULT_PATH` from `~/.claude/forge.conf`:

```bash
# Resolve marker path from forge.conf VAULT_PATH
FORGE_CONF="$HOME_DIR/.claude/forge.conf"
if [ ! -f "$FORGE_CONF" ]; then
  echo "[forge-context] ERROR: forge.conf not found at $FORGE_CONF" >&2
  exit 1
fi
VAULT_PATH=$(grep '^VAULT_PATH=' "$FORGE_CONF" | cut -d= -f2-)
if [ -z "$VAULT_PATH" ]; then
  echo "[forge-context] ERROR: VAULT_PATH not set in $FORGE_CONF" >&2
  exit 1
fi
MARKER="$VAULT_PATH/_shared/forge-active"
```

**Step 3: Verify the script still loads MARKER correctly**

Run: `bash -c 'set -e; source /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge/adapters/claude-code/scripts/forge-context.sh status 2>&1 | head -5; echo MARKER=$MARKER'` (sourcing won't quite work because it's a script with positional args — instead, run a sub-shell that just sources to inspect)

Better: temporarily add `echo "MARKER=$MARKER"` after the resolver, run any subcommand, confirm it prints the new path. Then remove the echo.

Run: `bash /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge/adapters/claude-code/scripts/forge-context.sh status 2>&1`
Expected: prints status without errors AND (if echo added) shows `MARKER=/Users/shiva.bernhard@m10s.io/__DEV/Vault/_shared/forge-active`.

**Step 4: NO commit yet** — bundle with reconciliation function in next task.

---

### Task 2: Add reconciliation function to `forge-context.sh`

**Files:**
- Modify: `adapters/claude-code/scripts/forge-context.sh` (append a function)

**Step 1: Add `reconcile_marker` function**

Append after the resolver, before any subcommand handling:

```bash
# Reconcile marker against most-recent-checkpoint frontmatter.
# Emits a one-line warning to stderr if marker disagrees with truth.
# Skips silently for missing/empty/__pending__ markers.
reconcile_marker() {
  if [ ! -f "$MARKER" ]; then
    return 0
  fi
  local marker_value
  marker_value=$(head -1 "$MARKER" 2>/dev/null | tr -d '[:space:]')
  if [ -z "$marker_value" ] || [ "$marker_value" = "__pending__" ]; then
    return 0
  fi
  # Find most recent checkpoint by `date:` frontmatter, tiebreak by mtime
  local newest_checkpoint
  newest_checkpoint=$(find "$VAULT_PATH" -path '*/current-checkpoint.md' -print0 2>/dev/null | \
    xargs -0 ls -t 2>/dev/null | head -1)
  if [ -z "$newest_checkpoint" ]; then
    return 0
  fi
  local checkpoint_project
  checkpoint_project=$(grep '^project:' "$newest_checkpoint" 2>/dev/null | head -1 | sed 's/project:[[:space:]]*//' | tr -d '[:space:]')
  local checkpoint_date
  checkpoint_date=$(grep '^date:' "$newest_checkpoint" 2>/dev/null | head -1 | sed 's/date:[[:space:]]*//' | tr -d '[:space:]')
  if [ -n "$checkpoint_project" ] && [ "$checkpoint_project" != "$marker_value" ]; then
    echo "[Keeper] Marker mismatch: forge-active says \"$marker_value\" but most recent checkpoint is for \"$checkpoint_project\" (${checkpoint_date:-unknown date}). If this is intentional cross-env work, ignore. Otherwise: switch projects or update the marker." >&2
  fi
}
```

**Step 2: Verify function syntactically loads**

Run: `bash -n /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge/adapters/claude-code/scripts/forge-context.sh`
Expected: no output (syntax check passes).

**Step 3: Manual smoke test of reconcile_marker**

In a sub-shell, source the relevant pieces and call `reconcile_marker`:

```bash
bash <<'EOF'
HOME_DIR="$HOME"
VAULT_PATH="/Users/shiva.bernhard@m10s.io/__DEV/Vault"
MARKER="$VAULT_PATH/_shared/forge-active"
# Function body inline (copy from forge-context.sh)
reconcile_marker() {
  # ... paste the function body ...
}
# Pretend the marker says "FINN"
echo "FINN" > /tmp/test-marker
MARKER=/tmp/test-marker reconcile_marker
EOF
```

Expected: emits warning if newest checkpoint's `project:` is not "FINN". (The `current-checkpoint.md` we just wrote has `project: forge` so we'd expect a mismatch warning.)

**Step 4: Commit**

```bash
git -C /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge add adapters/claude-code/scripts/forge-context.sh
git -C /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge commit -m "Add MARKER_PATH resolver + reconcile_marker to forge-context.sh"
```

---

## Phase 2 — Repo: update other consumers

### Task 3: Update `statusline.sh` to use new marker + handle 4 states

**Files:**
- Modify: `adapters/claude-code/scripts/statusline.sh:47`

**Step 1: Read current statusline marker handling**

Run: `sed -n '40,70p' /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge/adapters/claude-code/scripts/statusline.sh`

**Step 2: Replace hardcoded path with resolver + 4-state rendering**

Replace the `if [ -f "$HOME/.claude/forge-active" ]; then ... fi` block with:

```bash
# Resolve marker path
FORGE_CONF="$HOME/.claude/forge.conf"
MARKER=""
if [ -f "$FORGE_CONF" ]; then
  VAULT_PATH=$(grep '^VAULT_PATH=' "$FORGE_CONF" | cut -d= -f2-)
  [ -n "$VAULT_PATH" ] && MARKER="$VAULT_PATH/_shared/forge-active"
fi

if [ -n "$MARKER" ] && [ -f "$MARKER" ]; then
  marker_value=$(head -1 "$MARKER" 2>/dev/null | tr -d '[:space:]')
  if [ -z "$marker_value" ]; then
    forge_chip="[Forge | -]"
  elif [ "$marker_value" = "__pending__" ]; then
    forge_chip="[Forge | choosing…]"
  else
    forge_chip="[Forge | $marker_value]"
  fi
else
  forge_chip=""
fi
```

(Adapt variable names to existing script conventions — read the surrounding code first.)

**Step 3: Verify statusline still runs without errors**

Run: `bash /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge/adapters/claude-code/scripts/statusline.sh < /dev/null 2>&1 | head -5`
Expected: produces normal statusline output, no shell errors.

**Step 4: NO commit yet** — bundle with forge-compaction.sh next.

---

### Task 4: Update `forge-compaction.sh` to use new marker + call reconciliation in `post`

**Files:**
- Modify: `adapters/claude-code/hooks/forge-compaction.sh:9` and `post` branch

**Step 1: Read current file**

Run: `cat /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge/adapters/claude-code/hooks/forge-compaction.sh`

**Step 2: Replace hardcoded MARKER and add reconciliation call in `post`**

Replace `MARKER="$HOME/.claude/forge-active"` with the resolver block (same as forge-context.sh):

```bash
FORGE_CONF="$HOME/.claude/forge.conf"
if [ ! -f "$FORGE_CONF" ]; then
  echo "[forge-compaction] ERROR: forge.conf not found" >&2
  exit 0  # Don't block compaction on missing conf
fi
VAULT_PATH=$(grep '^VAULT_PATH=' "$FORGE_CONF" | cut -d= -f2-)
[ -z "$VAULT_PATH" ] && exit 0
MARKER="$VAULT_PATH/_shared/forge-active"
```

In the `post` branch (after compaction), source forge-context.sh's reconciliation function and call it:

```bash
if [ "$1" = "post" ]; then
  source "$HOME/.claude/scripts/forge-context.sh" >/dev/null 2>&1 || true
  reconcile_marker  # warns to stderr on mismatch
  # ... existing post logic ...
fi
```

**Caveat:** sourcing `forge-context.sh` may execute its main body. If so, instead duplicate the `reconcile_marker` function in forge-compaction.sh, or refactor `forge-context.sh` to make the function safely sourceable (guard `main` with `if [ "${BASH_SOURCE[0]}" = "$0" ]; then ... fi`). Investigate during implementation.

**Step 3: Syntax check**

Run: `bash -n /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge/adapters/claude-code/hooks/forge-compaction.sh`
Expected: no output.

**Step 4: Commit consumer updates**

```bash
git -C /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge add adapters/claude-code/scripts/statusline.sh adapters/claude-code/hooks/forge-compaction.sh
git -C /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge commit -m "statusline + forge-compaction: use VAULT_PATH-resolved marker, handle 4 states, add reconciliation on post"
```

---

## Phase 3 — Repo: update skills + docs

### Task 5: Update `forge/SKILL.md` entry checklist (write `__pending__` first)

**Files:**
- Modify: `adapters/claude-code/skills/forge/SKILL.md` — Step 1 of "Detect Environment"

**Step 1: Read current Step 1 of the entry checklist**

Run: `grep -n -A 20 "### 1. Detect Environment" /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge/adapters/claude-code/skills/forge/SKILL.md`

**Step 2: Rewrite Step 1**

Replace with two sub-steps:
- (1a) Write `__pending__` to `${VAULT_PATH}/_shared/forge-active` BEFORE running disambiguation.
- (1b) Once project is unambiguously chosen (by user input, single match, or explicit instruction), overwrite the marker with the project name.

Update the Marker convention block to add `__pending__` as the third valid state.

Update path references throughout the file from `~/.claude/forge-active` to `${VAULT_PATH}/_shared/forge-active`.

**Step 3: NO commit yet** — bundle with forge-exit + checkpoint skill in next two tasks.

---

### Task 6: Update `forge-exit/SKILL.md`

**Files:**
- Modify: `adapters/claude-code/skills/forge-exit/SKILL.md`

**Step 1: Read current marker references**

Run: `grep -n "forge-active" /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge/adapters/claude-code/skills/forge-exit/SKILL.md`

**Step 2: Replace path references with new location**

Update all `~/.claude/forge-active` → `${VAULT_PATH}/_shared/forge-active`. Edit (not Write) operation, and the empty value semantic ("Forge deactivated") is preserved.

**Step 3: NO commit yet** — bundle next.

---

### Task 7: Update `forge-checkpoint/SKILL.md` to call reconciliation

**Files:**
- Modify: `adapters/claude-code/skills/forge-checkpoint/SKILL.md` (or wherever the checkpoint skill lives — verify path first)

**Step 1: Find the checkpoint skill file**

Run: `find /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge/adapters/claude-code/skills -name "SKILL.md" -path "*checkpoint*"`

**Step 2: Append a reconciliation step**

After "Confirm" step, add:

```markdown
### Step 5: Reconcile marker (silent unless mismatch)

Run: `~/.claude/scripts/forge-context.sh reconcile-marker` (if implemented as subcommand) OR source the function and call it.

If a mismatch warning surfaces, repeat it to the user as `[Keeper] {warning}` so they decide what to do. Do not auto-fix.
```

This requires either adding a `reconcile-marker` subcommand to forge-context.sh, OR documenting that the function is called separately. Pick one during implementation; the subcommand is cleaner.

**Step 3: If subcommand approach: add it to forge-context.sh**

Add to the case statement in forge-context.sh:

```bash
reconcile-marker)
  reconcile_marker
  ;;
```

**Step 4: Commit skill changes**

```bash
git -C /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge add adapters/claude-code/skills/
git -C /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge commit -m "Skills: write __pending__ on entry, exit/checkpoint use new marker path, checkpoint reconciles"
```

If forge-context.sh got a new subcommand, include it in the same commit:

```bash
git -C /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge add adapters/claude-code/scripts/forge-context.sh adapters/claude-code/skills/
git -C /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge commit -m "Skills + reconcile-marker subcommand: marker lifecycle wired end-to-end"
```

---

### Task 8: Update `core/references/permission-patterns.md` (add 5th pitfall)

**Files:**
- Modify: `core/references/permission-patterns.md`

**Step 1: Read the current pitfall #4 section**

Run: `grep -n "## " /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge/core/references/permission-patterns.md`

**Step 2: Add a new section after pitfall #4**

```markdown
### 5. `~/.claude/` is a hardcoded sensitive zone — allowlist patterns DO NOT apply

Claude Code treats `~/.claude/` as a protected directory with mandatory permission prompts on Write/Edit/Bash operations targeting files inside it. **Allowlist patterns cannot suppress these prompts**, regardless of pattern shape (relative, absolute, glob, single `*`, double `*`).

```jsonc
"Write(.claude/forge-active)"                                  // ❌ chip text matches but still prompts
"Write(/Users/shiva.bernhard@m10s.io/.claude/forge-active)"   // ❌ same
"Edit(*/.claude/forge-active)"                                 // ❌ same (and single * doesn't cross / anyway)
```

**Why it bites:** the standard four pitfalls (single `*`, leading `*` in Bash, deny precedence, CWD-relative chip text) all give the impression that "right-shape pattern → match → no prompt." Inside `~/.claude/` that pipeline is bypassed by an upstream sensitive-zone check. The pattern is loaded, the chip matches, the matcher would have allowed — but the request is gated separately and prompts anyway.

**Verification (2026-04-29):** identical-shape patterns work in vault paths and fail in `~/.claude/`. See design doc `~/__DEV/PERSO/forge/.claude/plans/2026-04-29-marker-relocation-design.md`.

**The fix:** for runtime state files that need silent writes, **place them outside `~/.claude/`** (typically the vault). Reserve `~/.claude/` for files Claude Code itself manages (settings.json, hooks/, skills/, scripts/) where the prompt friction is acceptable — those files change rarely.

**Implications for past hypotheses:** pitfall #4 (matcher uses CWD-relative chip text) is correct for normal paths, but inside `~/.claude/` it's moot — no allowlist match fires regardless. Don't trust mid-session pattern experiments inside `~/.claude/`; they'll always fail.
```

**Step 3: NO commit yet** — bundle with ARCHITECTURE.md + ROLES.md path updates.

---

### Task 9: Update `docs/ARCHITECTURE.md` and `docs/ROLES.md` path references

**Files:**
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/ROLES.md`

**Step 1: Find marker references in each**

Run: `grep -n "forge-active" /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge/docs/ARCHITECTURE.md /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge/docs/ROLES.md`

**Step 2: Update path references**

Change `~/.claude/forge-active` → `${VAULT_PATH}/_shared/forge-active`. Note the vault dependency in ARCHITECTURE.md's runtime section.

**Step 3: Commit docs**

```bash
git -C /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge add core/references/permission-patterns.md docs/ARCHITECTURE.md docs/ROLES.md
git -C /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge commit -m "Docs: pitfall #5 (sensitive zone), update marker path references"
```

---

## Phase 4 — Sync to installed copies (`~/.claude/`)

### Task 10: Copy updated runtime files from repo to `~/.claude/`

**Files affected:**
- Source: `~/__DEV/PERSO/forge/adapters/claude-code/scripts/{forge-context.sh,statusline.sh}`
- Source: `~/__DEV/PERSO/forge/adapters/claude-code/hooks/forge-compaction.sh`
- Source: `~/__DEV/PERSO/forge/adapters/claude-code/skills/{forge,forge-exit,forge-checkpoint}/SKILL.md`
- Dest: corresponding `~/.claude/` paths

**Step 1: Verify dest paths**

Run: `ls /Users/shiva.bernhard@m10s.io/.claude/scripts/ /Users/shiva.bernhard@m10s.io/.claude/hooks/ /Users/shiva.bernhard@m10s.io/.claude/skills/forge*/SKILL.md`

**Step 2: Copy each file** (will prompt — sensitive zone)

```bash
cp /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge/adapters/claude-code/scripts/forge-context.sh /Users/shiva.bernhard@m10s.io/.claude/scripts/
cp /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge/adapters/claude-code/scripts/statusline.sh /Users/shiva.bernhard@m10s.io/.claude/
cp /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge/adapters/claude-code/hooks/forge-compaction.sh /Users/shiva.bernhard@m10s.io/.claude/hooks/
cp /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge/adapters/claude-code/skills/forge/SKILL.md /Users/shiva.bernhard@m10s.io/.claude/skills/forge/SKILL.md
cp /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge/adapters/claude-code/skills/forge-exit/SKILL.md /Users/shiva.bernhard@m10s.io/.claude/skills/forge-exit/SKILL.md
cp /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge/adapters/claude-code/skills/forge-checkpoint/SKILL.md /Users/shiva.bernhard@m10s.io/.claude/skills/forge-checkpoint/SKILL.md
```

Each `cp` writes into `~/.claude/` and will prompt. Approve each (~6 prompts). This is a one-time cost.

**Step 3: Verify checksums match**

Run: `for f in scripts/forge-context.sh scripts/statusline.sh hooks/forge-compaction.sh skills/forge/SKILL.md skills/forge-exit/SKILL.md skills/forge-checkpoint/SKILL.md; do diff -q /Users/shiva.bernhard@m10s.io/__DEV/PERSO/forge/adapters/claude-code/$f /Users/shiva.bernhard@m10s.io/.claude/$f 2>&1; done`

Expected: no diffs. (Path mismatch for statusline — it goes to `.claude/statusline.sh` not `.claude/scripts/statusline.sh` — adjust accordingly.)

**Step 4: NO commit** (installed files are not tracked by the repo)

---

## Phase 5 — In-session migration

### Task 11: Read current marker value, write to new location

**Files:**
- Read: `~/.claude/forge-active`
- Write: `~/__DEV/Vault/_shared/forge-active`

**Step 1: Read current value**

Run: `cat /Users/shiva.bernhard@m10s.io/.claude/forge-active`
Expected: `forge` (or whatever the current session's marker is).

**Step 2: Write to new location** (no prompt — vault is allowlisted)

Use the Write tool to create `/Users/shiva.bernhard@m10s.io/__DEV/Vault/_shared/forge-active` with the exact content from step 1.

**Step 3: Verify**

Run: `cat /Users/shiva.bernhard@m10s.io/__DEV/Vault/_shared/forge-active`
Expected: matches step 1.

---

### Task 12: Empty the old marker

**Files:**
- Edit: `~/.claude/forge-active`

**Step 1: Edit** (will prompt — final time)

Use the Edit tool to replace the contents with empty (`""`) — this is the deactivation semantic, kept consistent.

**Step 2: Verify**

Run: `wc -c /Users/shiva.bernhard@m10s.io/.claude/forge-active`
Expected: 0 or 1 (trailing newline).

---

### Task 13: Verify NO prompt on a marker write to the new location

**Step 1: Trigger a no-op write to the new marker via the new code path**

Run: `bash /Users/shiva.bernhard@m10s.io/.claude/scripts/forge-context.sh status` (or whichever subcommand exercises a marker read).

Manually edit the new marker via the Edit tool: change `forge` → `forge` (same content, exercises Write/Edit on the new path).

**Step 2: Confirm with user — NO prompt should have fired.**

If a prompt fires here, the relocation didn't take effect or the new path is also somehow sensitive. Stop and re-investigate.

---

## Phase 6 — Allowlist cleanup

### Task 14: Remove the 6 obsolete `forge-active` patterns from `settings.json`

**Files:**
- Modify: `~/.claude/settings.json` (via update-config skill)

**Step 1: Invoke update-config skill**

Use Skill tool with `update-config`, request: remove these 6 lines from `permissions.allow`:

```
"Write(*/.claude/forge-active)",
"Edit(*/.claude/forge-active)",
"Write(/Users/shiva.bernhard@m10s.io/.claude/forge-active)",
"Edit(/Users/shiva.bernhard@m10s.io/.claude/forge-active)",
"Write(.claude/forge-active)",
"Edit(.claude/forge-active)",
```

**Step 2: Verify settings.json is valid**

Run: `python3 -c "import json; d=json.load(open('/Users/shiva.bernhard@m10s.io/.claude/settings.json')); print('Valid. Allow rules:', len(d['permissions']['allow']))"`
Expected: valid JSON, allow rules count = 89 - 6 = 83.

---

## Phase 7 — Vault task hygiene

### Task 15: Update vault tasks

**Files:**
- Move: `Vault/PERSO/forge/tasks/open/2026-04-24-forge-active-edit-still-prompts.md` → `Vault/PERSO/forge/tasks/resolved/`
- Move: `Vault/PERSO/forge/tasks/open/2026-04-29-forge-active-marker-lifecycle.md` → `Vault/PERSO/forge/tasks/resolved/`
- Modify: `Vault/PERSO/forge/tasks/open/2026-04-20-wellness-preferences-permissions.md` (append findings + cross-link)

**Step 1: Move resolved task files**

Use Bash `mv` (vault paths are allowlisted, no prompt):

```bash
mv /Users/shiva.bernhard@m10s.io/__DEV/Vault/PERSO/forge/tasks/open/2026-04-24-forge-active-edit-still-prompts.md /Users/shiva.bernhard@m10s.io/__DEV/Vault/PERSO/forge/tasks/resolved/
mv /Users/shiva.bernhard@m10s.io/__DEV/Vault/PERSO/forge/tasks/open/2026-04-29-forge-active-marker-lifecycle.md /Users/shiva.bernhard@m10s.io/__DEV/Vault/PERSO/forge/tasks/resolved/
```

**Step 2: Append closing notes to each resolved task**

Edit each moved file to add a `## Resolution (2026-04-29)` section explaining what shipped and pointing at the design doc + commits.

**Step 3: Update the wellness task**

Edit `Vault/PERSO/forge/tasks/open/2026-04-20-wellness-preferences-permissions.md`. Append:

```markdown
## Update — 2026-04-29

Root cause now understood: `~/.claude/` is a hardcoded sensitive zone — allowlist patterns CANNOT suppress prompts there. See `core/references/permission-patterns.md` pitfall #5 and design doc `~/__DEV/PERSO/forge/.claude/plans/2026-04-29-marker-relocation-design.md`.

The forge-active marker was relocated out of `~/.claude/` to fix the same class of issue. The fix for wellness-preferences should follow the same pattern: relocate to a non-sensitive directory (likely the vault) and update the wellness skill + Python hooks accordingly. Likely target: `${VAULT_PATH}/_shared/wellness-preferences.json`.

Scope check before implementation: confirm the wellness module's expected path is configurable, and that all hook scripts (wellness-timer.py, wellness-precompact.py) handle the new path.
```

---

## Phase 8 — Final commit + checkpoint

### Task 16: Final checkpoint and confirmation

**Step 1: Write checkpoint**

Update `Vault/PERSO/forge/current-checkpoint.md` to reflect: marker relocation shipped, Tier 1 #1 + marker-lifecycle resolved, wellness task carries the new finding, awaiting next-session restart for full verification.

**Step 2: Confirm to user**

Summarize what's in place, what requires session restart to verify, and what's the next item from the queue.

**Step 3: Verify mid-session — final smoke test**

Run a marker-touching operation (e.g., `/forge-checkpoint` again) and confirm: NO prompt fires, AND the reconciliation function runs cleanly (no warning since marker = checkpoint project = forge).

---

## Verification gates (between phases)

| After Phase | Gate |
|---|---|
| 1 (foundation) | `bash -n` passes on forge-context.sh; `reconcile_marker` smoke test produces expected mismatch warning. |
| 2 (consumers) | `bash -n` passes on statusline.sh + forge-compaction.sh; manual run of statusline produces non-empty output. |
| 3 (skills + docs) | All committed; grep confirms zero remaining hard-coded `~/.claude/forge-active` references in `adapters/` and `docs/`. |
| 4 (install sync) | All file diffs empty between repo source and `~/.claude/` copies. |
| 5 (migration) | New marker contains the expected value; old marker is empty. |
| 6 (allowlist) | settings.json is valid JSON; allow rule count dropped by 6. |
| 7 (task hygiene) | Two tasks in resolved/, wellness task has the update appended. |
| 8 (final) | Mid-session marker write produces NO prompt (the verification we couldn't get this whole 04-29 session). |

## Risks & gotchas during execution

- **Sourcing forge-context.sh from forge-compaction.sh may execute its main flow.** Either guard the main with `if [ "${BASH_SOURCE[0]}" = "$0" ]; then ...`, or duplicate `reconcile_marker` in forge-compaction.sh.
- **The `find ... -path '*/current-checkpoint.md' | ls -t` chain orders by mtime, not by `date:` frontmatter.** Mtime is usually a fine proxy; document the limitation in a code comment rather than parsing YAML in shell.
- **Mid-session, the running session still uses the old in-memory consumer code paths.** The script files on disk are updated, but a process that's already running won't hot-reload. Effects of relocation are only fully exercised on next `/forge` entry. Document this for the user.
- **Phase 4 (file copies) WILL prompt 6 times.** Don't batch them in one Bash call hoping for one prompt — Claude Code prompts per file. Walk through deliberately.
- **If `settings.json` ends up invalid after Task 14**, restore from `~/.claude/backups/` and retry. update-config skill should handle this safely but verify.
