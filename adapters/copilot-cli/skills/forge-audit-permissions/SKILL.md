---
name: forge-audit-permissions
description: Audit Forge permission guidance. Run the settings/hook linter and inspect Copilot CLI's separate, location-scoped saved command approvals.
---

# Forge — Audit Permissions

Run the linter:

```bash
"${COPILOT_HOME:-$HOME/.copilot}/scripts/forge-permission-lint.sh"
```

The linter only checks legacy-shaped `.permissions` patterns and hook duplicates
in `settings.json`; a clean result does **not** validate Copilot CLI's saved
command approvals. Read `${COPILOT_HOME:-$HOME/.copilot}/permissions-config.json`
separately without changing it. Check the active CLI location (repository root
or non-repository working directory), the exact Forge script command identifiers
approved there, and whether commands are invoked directly or hidden inside
compound shell commands. Saved approvals do not automatically apply at another
location. If a script is already listed, do not recommend adding it again.
Separate shell approval prompts from file-overwrite and path-access prompts.

Explain any linter findings to the user with brief context for each:

- **check1-glob-not-crossing-slash:** Single `*` in `Write(...)` / `Edit(...)` doesn't cross `/`. The pattern silently never matches and the user sees prompts that should have been allowed. Fix: use absolute paths.
- **check2-bash-leading-star:** Leading `*` in `Bash(...)` is literal, not a wildcard. Pattern never matches. Use `prefix:*` form.
- **check3-allow-masked-by-deny:** A deny `Tool(*)` or `Tool(verb:*)` pattern masks the allow before it can match. Either remove the deny (if the allow was intended) or remove the redundant allow.
- **check4-hook-tilde-home-dup:** Same hook command registered with both `~/...` and `$HOME/...` (or absolute) forms — both fire, causing 2× hook execution. Fix: deduplicate to one form (Forge install.sh now handles this automatically).

Suggest fixes but **do NOT modify settings.json or permissions-config.json without
explicit separate user approval.** Do not claim that saved approvals prevent every
prompt without observing a real invocation.
