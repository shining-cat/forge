---
name: forge-vault-sync
description: Use mid-session to commit + push the vault when drift accumulates. Invoke with /forge-vault-sync, when the Vault state report shows uncommitted work, or when the user wants to clear vault drift.
---

# Forge Vault Sync

Help the user commit + push the vault when it's accumulated drift. The Keeper already SHOWS drift at session entry (the `--- Vault state ---` block in `do_recover`). This skill is the ACTION — when the user says "let's clean up the vault" or invokes `/forge-vault-sync`, run the report and offer the interactive commit path.

## Behavior

1. **Run the report** by invoking the bash subcommand:

   ```bash
   bash ~/.claude/scripts/forge-context.sh vault-sync
   ```

   The output is a categorized view of dirty vault files grouped by top-level directory, with a suggested commit message per group. It covers the outer vault repo AND every nested private repo in `VAULT_PRIVATE_ROOTS` (e.g. `PRO/` → its own GHEC remote), each shown under a `### Nested repo: <name> ###` section and pushed to its own origin.

2. **Surface the output verbatim** to the user. Don't paraphrase — the script's formatting is the canonical view.

3. **Offer the commit next step — two paths, depending on the control the user wants:**

   - **Unattended (Claude runs it):** `--commit` has no TTY when invoked via the Bash tool, so it falls back to the defaults (auto-Y): it commits *every* group and pushes each repo to its own origin. Use this when the user just wants the vault banked ("commit it", "sync the vault", "go ahead"). This is the common EOD/EOW path.

     ```bash
     bash ~/.claude/scripts/forge-context.sh vault-sync --commit
     ```

   - **Interactive per-group control (user runs it):** if the user wants to accept/skip individual groups, have them run the same command in their own shell (e.g. `! bash ~/.claude/scripts/forge-context.sh vault-sync --commit`). With a real TTY the script prompts Y/N per group and before pushing.

4. **When the user says "do it" / "go ahead" / "commit it"** — just run `--commit` via the Bash tool. It auto-accepts all groups and pushes. Only steer them to the interactive terminal path if they signal they want to *pick* which groups to commit.

## Constraints

- **Don't substitute your own commit messages** for the script's suggestions unless the user asks. The grouping heuristic and suggested-message convention are part of the discipline — overriding silently breaks the pattern.
- **Don't auto-stage anything.** The skill is read-or-action by user choice, never silently mutating git state.
- **Refusal cases** (the script handles these — relay them faithfully):
  - Vault not under git → suggest `git -C $VAULT_PATH init`
  - Vault clean → "Nothing to sync"
  - Pre-staged files exist → user must commit/unstage those first
- **Don't cache.** Always re-run the report fresh — vault state changes every session.

## Output contract

When the report shows N groups, the user has 4 paths:
- **Accept all:** Claude runs `--commit` via the Bash tool (auto-Y, commits + pushes every group in every repo), or the user runs it in their shell
- **Accept some:** user runs `--commit` in their own terminal and answers N to skipped groups (per-group choice needs a TTY)
- **Edit a message:** skip via `--commit`, then run `git add` + `git commit -m "their-message"` manually
- **Defer:** do nothing — vault stays dirty until next session

This skill never picks for the user. It surfaces options.

## Cross-references

- The vault drift warning at session entry comes from `do_recover` (same script, separate code path)
- Keeper Duty 6 (auto-archive) consumes `status: resolved` — that's the OPEN side of vault hygiene; this skill is the CLOSE side
- See `docs/PROJECT-STRUCTURE.md` for the vault hygiene workflow overview
