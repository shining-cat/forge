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

   The output is a categorized view of dirty vault files grouped by top-level directory, with a suggested commit message per group.

2. **Surface the output verbatim** to the user. Don't paraphrase — the script's formatting is the canonical view.

3. **Offer the interactive next step.** After the report, tell the user:

   > To commit + push interactively (Y/N per group, then push prompt), run in your shell:
   > ```
   > bash ~/.claude/scripts/forge-context.sh vault-sync --commit
   > ```
   > (Run from a real terminal, not via Claude — the interactive prompts read from the tty.)

4. **If the user says "do it" or "go ahead" or similar** — DON'T run `--commit` via Claude. Reiterate that the interactive flow needs a real terminal, and offer to walk through manually instead (Petra reads each suggested message, user confirms, you run `git add` + `git commit -m "..."` per group via the Bash tool).

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
- **Accept all:** run `--commit` in their shell
- **Accept some:** run `--commit` and answer N to skipped groups
- **Edit a message:** skip via `--commit`, then run `git add` + `git commit -m "their-message"` manually
- **Defer:** do nothing — vault stays dirty until next session

This skill never picks for the user. It surfaces options.

## Cross-references

- The vault drift warning at session entry comes from `do_recover` (same script, separate code path)
- Keeper Duty 6 (auto-archive) consumes `status: resolved` — that's the OPEN side of vault hygiene; this skill is the CLOSE side
- See `docs/PROJECT-STRUCTURE.md` for the vault hygiene workflow overview
