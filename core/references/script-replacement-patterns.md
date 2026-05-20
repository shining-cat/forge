# Script Replacement Patterns

Catalog of named patterns for converting recurrent Forge friction (permission prompts, prose-discipline failures, role drift) into deterministic script-enforced mitigations. Each entry follows a fixed 4-field structure plus a scaffold link.

Patterns are referenced by their kebab-case slug (e.g. `hook-injection`) from `forge-classify-friction.sh` and `forge-context.sh append-friction --pattern <slug>`.

---

## hook-injection

**When to use:** Recurrent prose discipline the agent keeps failing to follow despite explicit rules (header drift, time-guessing, format adherence).

**How it works:** A Claude Code hook (UserPromptSubmit, PreToolUse, or SessionStart) intercepts the agent's flow and injects the exact required string as `additionalContext`. The agent reads it as a system reminder and cannot "forget" it — the injection happens at every relevant boundary.

**Exemplar:** `inject-current-time.sh` (UserPromptSubmit hook). Originally emitted just current time to fix time-guessing; later extended to emit literal `[Forge: ENV/Project | HH:MM]` to fix header drift. One script, two prose rules dissolved.

**Anti-pattern:** Rules that require agent judgment ("use forge metaphors", "be terse") have nothing concrete to inject. Hook injection only works for verbatim-strings, not stylistic discipline.

**Scaffold:** [adapters/claude-code/hooks/inject-current-time.sh](../../adapters/claude-code/hooks/inject-current-time.sh)

---

## wrapper-subcommand

**When to use:** The agent keeps triggering permission prompts via direct file writes, heredocs, or shell patterns that aren't in the allowlist — but the underlying operation is safe and frequent.

**How it works:** Add a subcommand to `forge-context.sh` (which is fully allowlisted) that performs the operation. Replace the prose rule "use Write tool" with "use `forge-context.sh <subcmd>`". The script becomes the permission boundary; the agent calls one allowlisted thing instead of N adjacent things.

**Exemplar:** `forge-context.sh set-marker`. Replaced ad-hoc Write calls to the marker file (which triggered overwrite-existing-file confirmations) with three named forms (`pending` / `active <project>` / `clear`). Same for `append-braindump` replacing heredoc patterns.

**Anti-pattern:** Wrapping operations the agent should NOT do silently (e.g. `git push`). Wrappers should encode safe operations, not bypass safety checks.

**Scaffold:** [adapters/claude-code/scripts/forge-context.sh](../../adapters/claude-code/scripts/forge-context.sh) — see `do_set_marker` / `do_append_braindump`

---

## marker-state-guard

**When to use:** A hook fires side effects (nags, prompts, blocks) when it shouldn't — usually because it doesn't check whether Forge is in the right state for those side effects.

**How it works:** Hook reads the marker file (`$VAULT/_shared/forge-active`) and exits early if state is wrong (`__pending__` during entry, JSON owned by different session, etc.). The check is one extra branch; the suppression is total.

**Exemplar:** PR #9 A+C checkpoint-nag suppression. The Stop hook now reads the marker and skips the nag during the grace window AND when activity stops are below threshold. Two gates, both keyed to marker state.

**Anti-pattern:** Replacing the guard with "agent should know not to fire" — moves the rule from script-enforced to prose-asked.

**Scaffold:** [adapters/claude-code/scripts/forge-context.sh](../../adapters/claude-code/scripts/forge-context.sh) — see `do_stop` (NAG_SUPPRESS_GRACE_MIN / NAG_SUPPRESS_ACTIVITY_STOPS)

---

## allowlist-patch

**When to use:** A safe, recurrent operation triggers permission prompts because no `settings.json` allow pattern matches it (often due to glob subtleties — single `*` not crossing `/`, leading `*` literal in Bash, etc.).

**How it works:** Add a precise `Bash(...)` / `Write(...)` / `Edit(...)` pattern to `~/.claude/settings.json` permissions. Use absolute paths (single `*` doesn't cross `/`) and proper `prefix*` form (leading `*` is literal in Bash).

**Exemplar:** `Bash(~/.claude/scripts/forge-context.sh *)` — written with the trailing space + `*` so subcommands match. Belt-and-braces both `~/...` and absolute forms because tilde expansion isn't verified for permission rules.

**Anti-pattern:** Over-broad patterns (e.g. `Bash(*)`) that silently allow destructive operations. `forge-permission-lint.sh` catches some of these; review carefully.

**Scaffold:** See [core/references/permission-patterns.md](permission-patterns.md) for the gotchas catalog.

---

## template-slot

**When to use:** The agent has to reproduce verbatim multi-line text (file headers, frontmatter blocks, structured entries) and keeps drifting from the canonical form.

**How it works:** Convert the verbatim text into a template file. Add a subcommand or script that fills slots and writes the result. The agent calls the filler, not "remember to write X structure".

**Exemplar:** Vault templates at `core/vault-templates/` (task.md, checkpoint.md, etc.). The agent doesn't reconstruct frontmatter from memory; it copies the template and fills slots.

**Anti-pattern:** Templates with embedded prose telling the agent what to put in each slot — collapses back to prose discipline. Slots should be `{{name}}` markers that a filler script substitutes.

**Scaffold:** [core/vault-templates/task.md](../vault-templates/task.md)

---

## Adding new patterns

If the classifier returns `needs_new_pattern`, the Toolsmith reviews recent `needs_new_pattern` entries in `$VAULT/_shared/friction-classified.json` and either:

1. Adds a new entry here (with all 4 fields + scaffold link), then updates `forge-classify-friction.sh` decision tree to route to it.
2. Merges the case into an existing pattern (and updates `friction-classifier.md` to broaden that branch).

After either change, run `core/tests/lint-catalog.sh` to verify structural integrity.
