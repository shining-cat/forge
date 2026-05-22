# Forge Permissions — Reference Catalog

Forge `install.sh` writes a baseline allow-list into `~/.claude/settings.json` so fresh installs don't trip permission prompts on every Forge action. This file catalogs every operation Forge performs and the corresponding permission pattern.

**Conventions:**

- `$HOME` and `$VAULT_PATH` are substituted by `install.sh` at install time via shell expansion
- Patterns use Claude Code matcher syntax. See [`permission-patterns.md`](permission-patterns.md) for known pitfalls (leading `*` is literal in Bash, single `*` doesn't cross `/`, `**` is the recursive form)
- These patterns are validated by `forge-permission-lint.sh` at the end of `install.sh`. Any pattern that trips check1/check2/check3/check4 fails the install (fail-closed)

---

## Baseline (always installed)

### Forge scripts (`~/.claude/scripts/`)

| Script | Pattern | Used by |
|---|---|---|
| `forge-context.sh` | `Bash($HOME/.claude/scripts/forge-context.sh:*)` | PreToolUse / PostToolUse / Stop hooks; manual `recover` subcommand at session start |
| `forge-permission-lint.sh` | `Bash($HOME/.claude/scripts/forge-permission-lint.sh:*)` | end of `install.sh` (fail-closed) + `/forge-audit-permissions` skill |

### Claude Code statusline (`~/.claude/`)

| Script | Pattern | Used by |
|---|---|---|
| `statusline.sh` | `Bash($HOME/.claude/statusline.sh:*)` | Claude Code status line component — path matches `settings.json` `statusLine.command` (deploys to `~/.claude/` root, not `scripts/`) |

### Forge hooks (`~/.claude/hooks/`)

| Hook | Pattern | Triggered by |
|---|---|---|
| `forge-compaction.sh` | `Bash($HOME/.claude/hooks/forge-compaction.sh:*)` | PreCompact event |
| `approval-notifier.sh` | `Bash($HOME/.claude/hooks/approval-notifier.sh:*)` | Notification event |
| `forge-vault-plan-guard.sh` | `Bash($HOME/.claude/hooks/forge-vault-plan-guard.sh:*)` | PreToolUse on Write/Edit (blocks plans outside the vault) |

### Forge config (`~/.claude/forge.conf`)

| Operation | Pattern | When |
|---|---|---|
| Read | `Read($HOME/.claude/forge.conf)` | session start, conditional checks |
| Edit | `Edit($HOME/.claude/forge.conf)` | onboarding, model assignment changes |

### Vault (`$VAULT_PATH`)

Forge reads, writes, and edits files throughout the vault — checkpoints, braindumps, task files, friction log, decisions, BACKLOGs, marker files. Recursive coverage required.

| Operation | Pattern |
|---|---|
| Read | `Read($VAULT_PATH/**)` |
| Write | `Write($VAULT_PATH/**)` |
| Edit | `Edit($VAULT_PATH/**)` |

---

## Conditional (wellness coach)

Installed only if `WELLNESS_ENABLED=true` in `forge.conf` (set during onboarding when the user opts in).

| Surface | Pattern | Notes |
|---|---|---|
| Python hooks | `Bash(python3:$HOME/.claude/skills/wellness-coach/hooks/*)` | `wellness-timer.py`, `wellness-precompact.py` |
| Helper scripts | `Bash($HOME/.claude/skills/wellness-coach/scripts/*)` | various `.sh` scripts |

---

## Conditional (permissive shell wrappers — opt-in)

Installed only if `PERMISSIVE_BASH_WRAPPERS=true` in `forge.conf`. Default is `false`. `install.sh` prompts interactively the first time it runs, persists the answer, and skips the prompt on re-installs.

| Surface | Pattern | Notes |
|---|---|---|
| `bash -c "…"` | `Bash(bash -c:*)` | inline shell wrapper |
| `zsh -c "…"` | `Bash(zsh -c:*)` | inline shell wrapper |

**Why it exists:** Claude Code's Bash matcher is prefix-only (pitfall #2 in [`permission-patterns.md`](permission-patterns.md)). A grant like `Bash(pnpm:*)` does NOT cover `Bash(cd dir && pnpm install)` because the command starts with `cd`, not `pnpm`. Multi-step setup steps (Forge install, wellness-coach setup, gws-auth recovery) routinely hit this and require either narrowing the command or pinning the exact compound string in `settings.local.json`.

**The tradeoff:** these wrappers don't bypass the matcher — they trip it earlier. Once `Bash(bash -c:*)` matches, the entire `bash -c '<anything>'` payload runs. Equivalent to saying "I trust myself when I deliberately invoke a one-shot shell." Suitable for power users who already accept that tradeoff. Not suitable as a universal default.

**Patterns we intentionally do NOT ship**, even with `PERMISSIVE_BASH_WRAPPERS=true`:

- `Bash(cd:*)` and `Bash(cd * && *)` — these match any `cd`-prefixed compound, which in combination with matcher behavior amounts to "anything you can reach via `cd <anywhere> && …`". Too broad for a baseline. Users who want this can add it to their own `~/.claude/settings.json` after weighing the risk.

**Relationship to `forge-permission-lint.sh`:** the lint script (also surfaced as the `/forge-audit-permissions` skill) surfaces *anti-patterns* in existing settings (drift detection — see pitfalls #1, #2, #4 in [`permission-patterns.md`](permission-patterns.md)). It does NOT propose or apply baseline patterns. The opt-in surface above is install-time only; the lint stays a separate runtime tool.

---

## Maintenance

When adding a new Forge surface (script, hook, skill that performs filesystem operations), update this catalog AND `install.sh`'s `PERMS_TO_ADD` array in the same commit.

The cluster #6 linter (`forge-permission-lint.sh`) catches some classes of bad patterns at install time but **cannot detect missing patterns** — those surface only as user prompts. A new Forge surface without a corresponding catalog entry = silent friction for fresh installs.

---

## Related

- [`permission-patterns.md`](permission-patterns.md) — known pitfalls and matcher conventions
- `forge-permission-lint.sh` — runtime validator
- `install.sh` — applies this catalog at install time
