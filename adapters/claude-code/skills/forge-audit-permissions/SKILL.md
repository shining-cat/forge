---
name: forge-audit-permissions
description: Run the Forge permission/hook linter against ~/.claude/settings.json. Surfaces known anti-patterns (drift between intended and actual settings).
---

# Forge — Audit Permissions

Run the linter:

```bash
~/.claude/scripts/forge-permission-lint.sh
```

Then explain any findings to the user with brief context for each:

- **check1-glob-not-crossing-slash:** Single `*` in `Write(...)` / `Edit(...)` doesn't cross `/`. The pattern silently never matches and the user sees prompts that should have been allowed. Fix: use absolute paths.
- **check2-bash-leading-star:** Leading `*` in `Bash(...)` is literal, not a wildcard. Pattern never matches. Use `prefix:*` form.
- **check3-allow-masked-by-deny:** A deny `Tool(*)` or `Tool(verb:*)` pattern masks the allow before it can match. Either remove the deny (if the allow was intended) or remove the redundant allow.
- **check4-hook-tilde-home-dup:** Same hook command registered with both `~/...` and `$HOME/...` (or absolute) forms — both fire, causing 2× hook execution. Fix: deduplicate to one form (Forge install.sh now handles this automatically).

Suggest fixes but **do NOT modify settings.json without explicit user request.**
