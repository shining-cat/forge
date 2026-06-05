# Draft tasks — quick-capture lifecycle

A 5-second capture path for half-formed ideas, with zero involvement from Petra at capture-time. Drafts accumulate in your vault; the weekly wrap triages them; on-demand refinement turns the survivors into proper tasks.

> **Why this exists.** The default flow — telling Petra *"log this for later"* — takes 30-60 seconds of conversation that pulls focus from whatever you were doing. For genuinely small, half-formed ideas, that's overhead. This lets you capture in seconds without leaving Obsidian, and Petra catches up later in a structured ceremony.
>
> The asymmetry is the point: **capture should be cheap, refinement is what Petra is good at**.

For the daily-workflow context this fits into, see the [README](../README.md). For the underlying vault folder layout (`tasks/draft/`, `tasks/open/`), see [PROJECT-STRUCTURE.md](PROJECT-STRUCTURE.md).

---

## The full lifecycle

```
Capture (Obsidian hotkey, ~5s)
        ↓
   tasks/draft/                  ← drafts accumulate here
        ↓
Weekly triage (/forge-weekly, Friday)
        ↓
   BACKLOG.md row                ← `[draft] refine: {title}`
        ↓
On-demand refinement (with Petra)
        ↓
   tasks/open/                   ← proper task file
```

Three stages, each described below.

---

## Stage 1 — Setup (one-time, ~5 minutes)

This uses [Templater](https://github.com/SilentVoid13/Templater), a community Obsidian plugin. Forge ships the `draft.md` template + this docs page; the plugin install + wiring is yours to maintain (same model as superpowers — required dep, user-installed).

### 1. Install Templater

Obsidian → Settings → Community plugins → Browse → search **Templater** → Install → Enable.

### 2. Point Templater at the vault's template folder

Settings → Templater → **Template folder location** → set to `_templates`.

Forge's `install.sh` creates `_templates/` at the vault root with `draft.md` already seeded.

### 3. Enable Folder Templates

Settings → Templater → **Folder Templates** → toggle on.

### 4. Map the draft folder(s) to the draft template

Under Folder Templates, add at minimum:

| Folder                | Template              |
| --------------------- | --------------------- |
| `_shared/tasks/draft` | `_templates/draft.md` |

This makes new files in `_shared/tasks/draft/` get the draft template's frontmatter and structure automatically.

**Optional — per-project capture.** If you usually know at capture-time which project a draft belongs to, add additional mappings:

| Folder | Template |
|---|---|
| `WORK/my-app/tasks/draft` | `_templates/draft.md` |
| `PERSO/side-project/tasks/draft` | `_templates/draft.md` |
| (etc — one per project) | |

If you don't bother, drop everything in `_shared/tasks/draft/` and the weekly triage assigns project then.

### 5. Bind a hotkey

Settings → Hotkeys → search **Templater: Create new note from template** → bind a hotkey you'll remember (e.g. `Cmd-Shift-D` for "draft").

---

## Stage 2 — Capture (daily, ~5 seconds)

1. An idea surfaces. You're in Obsidian (or hit your global Obsidian hotkey from anywhere).
2. Press your bound hotkey (e.g. `Cmd-Shift-D`).
3. Templater prompts for the destination folder. Pick `_shared/tasks/draft/` (or a per-project draft folder if you've set them up).
4. Type a one-line title for the file.
5. The file opens with frontmatter pre-filled. Type your one-line idea below the heading. Save.

Total time: ~3-5 seconds. Zero conversation with Claude.

Drafts live where you dropped them until the weekly triage. The vault syncs them like any other file.

---

## Stage 3 — Weekly triage (Friday, via `/forge-weekly`)

Invoking `/forge-weekly` on a Friday afternoon runs the Quartermaster ceremony. **Step 2 of the ceremony is draft triage**: Petra walks you through each draft file across all draft folders, asking per-draft:

- **Keep** — assign a project (if not already inferred from the folder); Petra files a row in that project's BACKLOG under a *"Drafts pending refinement"* cluster: `[draft] refine: {title}`
- **Discard** — move to `_discarded/` (a sibling folder with a grace period before auto-purge)
- **Defer** — leave in place; will surface again next week

The triage takes ~30 seconds per draft. After the ceremony, surviving drafts are visible in their project BACKLOG as `refine` rows, ready for on-demand pickup.

---

## Stage 4 — On-demand refinement (with Petra)

You nominate the refine row from the BACKLOG when you have headspace — same way you pick up any other task. The row looks like:

```
| [[2026-06-02T15-50-some-draft]] | XS | ? | refine | Some draft title — captured 2026-06-02T15:50 |
```

The wikilink resolves to the draft file in `tasks/draft/`.

Petra opens the draft and walks the standard refinement questions:

1. **What** — restate the idea in 1-2 sentences (the raw draft is often cryptic to future-you)
2. **Why** — what triggered this? What does shipping it change?
3. **Scope** — single task, or does it cluster with others (umbrella candidate)?
4. **Effort** — XS / S / M / L gut estimate
5. **Impact** — L / M / H gut estimate
6. **Priority** — vs current BACKLOG
7. **Dependencies / blockers** — anything that must land first?
8. **Next step** — concrete first action

These are starter questions, not a script. Some drafts need 30 seconds (idea was already clear); others need 10 minutes of design before they're ready to file.

**Output:** a proper task file at `{ENV}/{PROJECT}/tasks/open/YYYY-MM-DD-<slug>.md` using the standard `_templates/task.md` template. The `created:` date is when the refined task is filed, NOT when the draft was captured — the draft was a seed; the task is the artifact.

**Cleanup** (all in the same action that files the refined task):

1. Delete the draft file from `tasks/draft/`
2. Remove the `[draft] refine:` row from the BACKLOG; add the proper task row in its appropriate cluster
3. If *"Drafts pending refinement"* is now empty, drop the cluster header too (lazy delete — re-created on next weekly triage)

### When NOT to refine

- **Stale + irrelevant** → discard at the next weekly triage. Don't refine what you wouldn't pick up.
- **Duplicates an open task** → merge: copy any new context into the existing task, discard the draft.
- **Half a sentence with no context** → ask yourself what you meant. If you don't remember, discard. Forcing refinement on incoherent seeds wastes more time than the capture saved.

---

## Notes

- **Templater is third-party, not bundled.** Forge ships `draft.md` + this docs page. Plugin install + Folder Template wiring is yours.
- **`_templates/draft.md` is A2-preserve in Forge's install policy.** If you customize the template, re-installing Forge won't clobber your changes — upstream lands as a `.upstream.<ts>` sibling for diff.
- **Fully optional.** If you don't install Templater, the rest of Forge works exactly as before; you just don't get the 5-second capture path. The Petra-mediated *"log this for later"* flow stays available in-conversation either way.
