# Draft refinement protocol

How `[draft] refine: {title}` BACKLOG rows turn into proper tasks. On-demand, no special ceremony — just normal task pickup.

This is Slice C of the [user-draft-task-capture](https://github.com/shining-cat/forge/issues?q=user-draft-task-capture) feature; companion to [obsidian-draft-capture.md](obsidian-draft-capture.md) (Slice A — the capture path) and the `/forge-weekly` Step 2 draft-triage (Slice B — the weekly inbox).

## What's the entry point

A row like this lives in your project's `BACKLOG.md` under the "Drafts pending refinement" cluster (placed by `/forge-weekly` Step 2):

```
| [[2026-06-02T15-50-some-draft]] | XS | ? | refine | Some draft title — captured 2026-06-02T15:50 |
```

The wikilink points to the draft file at `{ENV}/{PROJECT}/tasks/draft/{filename}.md` (moved there from `_shared/tasks/draft/` during weekly triage if it landed without a project assignment).

The status `refine` signals: this isn't open work yet — it's a seed waiting to be turned into a real task.

## When you pick it up

The user nominates the row from BACKLOG ("let's refine that draft / let's turn this into a real task"). Petra opens the draft file and walks the standard refinement questions:

1. **What** — restate the idea in 1-2 sentences. The draft is often cryptic to future-you.
2. **Why** — what triggered this? What does shipping it change?
3. **Scope** — single task, or does it cluster with others (umbrella candidate)?
4. **Effort** — XS / S / M / L gut estimate
5. **Impact** — L / M / H gut estimate
6. **Priority** — low / medium / high vs current BACKLOG
7. **Dependencies / blockers** — anything that must land first?
8. **Next step** — concrete first action if this gets picked up

The conversation is ad-hoc — these are starter questions, not a script. Some drafts need 30 seconds (the idea was already clear); others need 10 minutes of design before they're ready to file.

## What gets produced

A proper task file at `{ENV}/{PROJECT}/tasks/open/YYYY-MM-DD-<slug>.md` using the standard `_templates/task.md` template. The `created:` frontmatter date reflects when the refined task is filed, NOT when the draft was captured — the draft was a seed; the task is the artifact.

## Cleanup after refinement

Three things, all in the same action that files the refined task:

1. **Delete the draft file** from `tasks/draft/`. The raw draft is not preserved (per the 2026-06-01 design decision — refined task supersedes the seed, no traceability link kept).
2. **Replace the BACKLOG row** — remove the `[draft] refine: {title}` row from the "Drafts pending refinement" cluster; add the proper task row in its appropriate cluster (Hot / Measurement / etc., per Keeper's judgment).
3. **Prune empty cluster** — if "Drafts pending refinement" is now empty (no other refine rows), remove the cluster header too. Lazy delete; it'll get re-created by the next weekly triage if more drafts come in.

## When NOT to refine

- **Stale + irrelevant** → discard at the next weekly triage (move to `_discarded/`); don't keep refining what you'd no longer pick up. The discard path exists for exactly this case.
- **Duplicates an open task** → merge: copy any new context from the draft into the existing task's body, then discard the draft + remove its refine row. No new task file needed.
- **Half a sentence with no context** → ask the user what they meant. If they don't remember either, discard. Forcing refinement on incoherent seeds wastes more time than the capture saved.

## Why no `forge-refine-draft` skill

The original plan flagged this as an optional polish: a skill that opens the draft + walks the standard questions. Deliberately deferred. Reason: refinement conversations vary too much — fixed-script automation would either feel heavy (forced through irrelevant questions) or too sparse (missing nuance for complex drafts). The ad-hoc Petra-led conversation handles the variance better.

If refinement-friction surfaces (e.g. Petra consistently forgets to ask about priority, or always misses dependency-checking), file it as friction; codify the missing step into a skill or feedback memory then. Until that signal arrives, the on-demand path is the right tool.

## Related

- [obsidian-draft-capture.md](obsidian-draft-capture.md) — upstream capture path (Slice A)
- `adapters/claude-code/skills/forge-weekly/SKILL.md` — `/forge-weekly` Step 2 draft-triage that produces `[draft] refine:` rows (Slice B)
- `Vault/PERSO/forge/tasks/resolved/2026-05-05-user-draft-task-capture.md` — the umbrella task that designed and shipped this whole feature
