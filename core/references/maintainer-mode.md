# Maintainer mode vs end-user mode

Background for the `**Maintainer mode (user-mode by default):**` stub in `forge/SKILL.md` Step 7. The short version is one line — *"end-user mode suppresses meta-work suggestions; maintainer mode surfaces them"*. Load this file when Petra is about to emit a suggestion and needs to decide whether it counts as meta-work.

## The setting

Read `MAINTAINER_MODE` from `~/.claude/forge.conf` at session entry. Default `false` = end-user mode; `true` = maintainer mode.

## End-user mode (default)

Petra is a working partner, not a forge-machinery curator. **Suppress meta-work invitations** from entry summaries, checkpoint Next-Steps, and proactive suggestions.

Meta-work means:

- Friction-log writes (unless the friction is about user-facing Forge behavior — see Refiner rule in SKILL.md)
- `decisions/` curation, archival, INDEX.md maintenance
- BACKLOG.md grooming / task triage
- Vault hygiene tasks (template tuning, hook tweaks, skill polish)
- Forge-internal audits ("should we revisit X?")

In end-user mode, those tasks may still be DONE when the user asks for them — but they are not surfaced as ambient threads. If they leak into Next-Steps of a checkpoint, drop them silently when summarizing.

## Maintainer mode

Full surface. Meta-work IS the work; surface it normally. Entry summaries can mention *"3 friction events pending classification"* or *"INDEX has 4 stale decisions"*; checkpoint Next-Steps can include vault-hygiene tasks; proactive suggestions can point at forge-internal followups.

## Script-level complement

`forge-context.sh recover` already gates the open-task audit and BACKLOG staleness audit on `is_maintainer_mode` — in end-user mode those sections never appear in the entry output, so there's nothing to filter at the persona level for them.

Petra's job is to suppress *suggestions/synthesis* about meta-work; the script's job is to not surface the raw audit data in the first place. The two layers are independent — the persona-level rule still applies to any meta-work signal that DOES come through other channels (friction-log tail, vault drift line, etc.).

The audits remain callable on demand via `forge-context.sh open-task-audit` / `backlog-audit` regardless of mode, for the rare end-user who wants a one-off check.

## The decision rule

When in doubt about a given suggestion: ask *"is this about Forge's own machinery, or about the user's project work?"* If the former and `MAINTAINER_MODE=false`, suppress.

## See also

- `forge-context.sh` `is_maintainer_mode` — the script-level gate
- `references/lifecycle.md` — where in the session lifecycle Petra reads the flag
