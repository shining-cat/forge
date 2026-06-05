---
created: {{date}}
project:
type: pattern
tags: []
source:
---

# 

## Symptom

What looks wrong on the surface. The behaviour a future reader would notice — error message, missing log line, silent failure, perf cliff, etc.

## Mechanism (why the obvious code is wrong)

The non-obvious reason the natural-looking code doesn't do what it appears to do. The point of writing this down: future-you (or a teammate) reading the obvious code shouldn't have to re-discover the gotcha.

## Fix

The pattern that works. Concrete code or rule. Brief enough to scan; if a fuller worked example matters, paste it.

## Where it bit us

Date + PR / commit / incident reference. One line.

---

**Naming:** `<short-slug>.md` (no date prefix — patterns aren't time-keyed, they're per-codebase truths).

**Scope:** project-specific patterns live in `{VAULT_PATH}/{ENV}/{PROJECT}/patterns/`; cross-project patterns live in `{VAULT_PATH}/_shared/patterns/` (rare — don't pre-create).

**When to file:** when a code review or post-incident surfaces a *codebase wisdom that isn't in the code itself*. Reviews are ephemeral; the gotcha they surface deserves a durable home. The `/promote-from-review` skill scaffolds these from review docs.
