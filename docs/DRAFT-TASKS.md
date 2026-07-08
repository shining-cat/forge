# Draft tasks — quick-capture lifecycle

A 5-second capture path for half-formed ideas, with zero involvement from Petra at capture-time. Drafts accumulate in your vault; the weekly wrap triages them; on-demand refinement turns the survivors into proper tasks.

> **Why this exists.** The default flow — telling Petra *"log this for later"* — takes 30-60 seconds of conversation that pulls focus from whatever you were doing. For genuinely small, half-formed ideas, that's overhead. This lets you capture in seconds without leaving Obsidian, and Petra catches up later in a structured ceremony.
>
> The asymmetry is the point: **capture should be cheap, refinement is what Petra is good at**.

For the daily-workflow context this fits into, see the [README](../README.md). For the underlying vault folder layout (`tasks/drafts/`, `tasks/open/`), see [PROJECT-STRUCTURE.md](PROJECT-STRUCTURE.md).

---

## The full lifecycle

```
Capture (Obsidian hotkey, ~5s)
        ↓
   tasks/drafts/                  ← drafts accumulate here
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

### 3. Enable "Trigger Templater on new file creation"

Settings → Templater → scroll to **"Trigger Templater on new file creation"** → toggle on.

This is the gate for the next step — without it, the **Folder Templates** section doesn't appear in the settings UI.

### 4. (Optional) Map per-project draft folders to the draft template

Under **Folder Templates** (now visible thanks to step 3), add a mapping for each project where you want draft capture to land in that project's own folder:

| Folder                           | Template              |
| -------------------------------- | --------------------- |
| `WORK/my-app/tasks/drafts`        | `_templates/draft.md` |
| `PERSO/side-project/tasks/drafts` | `_templates/draft.md` |
| (etc — one per project)          |                       |

When a new note is created **inside one of these folders** (via Obsidian's "new note" button while navigated there), Templater auto-applies the draft template.

**You don't need a mapping for `_shared/tasks/drafts/`** — the draft template itself auto-moves new files to that folder by default (see step 5). The per-project mappings above only matter if you want drafts to skip the `_shared` default and land in a specific project folder.

### 5. Bind a global hotkey

Go to **Obsidian Settings → Hotkeys** (left sidebar — *not* Templater's own "Template hotkeys" section, which is a different mechanism with confusing UI).

Search for **"Templater: Create new note from template"** and bind a hotkey you'll remember (e.g. `Cmd-Shift-D` for "draft").

When you hit it: Templater pops a template picker, you pick `draft.md`, a new file gets created. The template includes a `tp.file.move(...)` call that auto-relocates the new file to `_shared/tasks/drafts/` (unless it was already created inside a `tasks/drafts` folder via step 4's Folder Template mapping, in which case it stays put).

---

## Stage 2 — Capture (daily, ~5 seconds)

1. An idea surfaces. You're in Obsidian (or hit your global Obsidian hotkey from anywhere).
2. Press your bound hotkey (e.g. `Cmd-Shift-D`).
3. The template picker pops up. Type "draft" → select `draft.md`.
4. Templater prompts for the new file's name (defaults to "Untitled"). Type a one-line title.
5. The file opens with frontmatter pre-filled. **It auto-moves to `_shared/tasks/drafts/`** (via the template's `tp.file.move(...)` call) unless you created it inside a per-project draft folder you mapped in Stage 1 step 4.
6. Type your one-line idea below the heading. Save.

Total time: ~3-5 seconds. Zero conversation with Claude.

Drafts live where they landed until the weekly triage. The vault syncs them like any other file.

---

## Mobile capture (Android)

> **Suggestion, not a requirement.** The desktop hotkey above is the primary
> path. This extends the same draft pipeline to your phone, for when an idea
> strikes away from the laptop and the real cost is carrying it around in your
> head instead of putting it down and getting back to your life.

### Why Obsidian on the phone (and not a code-host app)

The draft pipeline is **sync-agnostic by design**: capture drops a `type: draft`
file into a `tasks/drafts/` folder, and the weekly triage picks it up regardless
of *how* the file got there. So mobile capture needs **no Forge code** — only
(1) the vault present on the phone and (2) a fast way to create a draft there.

Obsidian's own Android app is the right tool: it speaks markdown natively,
browses/searches the whole vault offline, and reuses the **same `draft.md`
template** as the desktop. A code-host mobile app (e.g. GitHub's) is built for
PRs/issues/review, not for browsing a knowledge vault or quick capture — it will
always feel crippled here. The cost (per-device plugin setup) is what keeps
credentials and config out of the synced repo.

### Rationale recap
- **Capture must be cheap.** Same asymmetry as desktop — capture in seconds, let
  the weekly triage do the structured work.
- **Work/personal separation is preserved.** Gitignored work areas (see
  `VAULT_PRIVATE_ROOTS` + the vault `.gitignore`) never reach the phone; the
  clone holds personal projects + `_shared` only.
- **A mobile-safe vault is required.** No tracked symlinks, no illegal filenames
  — see "Vault file portability" in [PROJECT-STRUCTURE.md](PROJECT-STRUCTURE.md).
  The mobile client deletes anything it can't represent.

### Install — Android, step by step

Two stages: get the vault syncing, then add a capture trigger.

#### Stage A — Sync the vault to the phone (obsidian-git)

> Obsidian's built-in Sync (paid) and iCloud also work; these steps use the free
> **Git** community plugin against your existing vault repo.

1. **Create a scoped access token** on your git host (GitHub: Settings →
   Developer settings → fine-grained PAT) limited to the vault repo, with
   **Contents: read and write**. (A classic token with `repo` scope also works.)
2. **Install the Obsidian Android app** and create a **new empty vault**.
3. **Install the Git plugin:** Settings → Community plugins → Browse → *Git* →
   Install → Enable.
4. **Set authentication:** Git plugin settings → username = your git-host login,
   password = the token.
5. **Clone:** command palette → *"Git: Clone an existing remote repo"* → paste
   the repo HTTPS URL. Only non-gitignored content arrives.
6. **Re-install the plugin in the cloned vault if it shows zero plugins.** Because
   `.obsidian/` is gitignored (by design — keeps the token out of the repo), a
   fresh clone arrives with no plugins. Re-install + enable *Git* in the now-active
   vault; it detects the existing `.git` (no re-clone).
7. **Auto-sync:** Git plugin settings → enable *Pull on startup* + a
   *Commit-and-sync interval* (e.g. 10 min) and/or *commit-and-sync on app
   background*. Set the commit author to your identity.

#### Stage B — A capture trigger

Install **Templater** (Community plugins → Browse → *Templater* → Enable) and set
its **Template folder** to `_templates`. The cloned vault already contains
`_templates/draft.md`. Then pick one:

**Option 1 — in-app (simplest, no extra apps).** Pin *"Templater: Create new note
from template"* to the mobile toolbar (Settings → Appearance → Manage mobile
toolbar), or run it from the command palette. Tap → pick `draft.md` → type the
idea. The template auto-moves the note to `_shared/tasks/drafts/`. ~3 taps.

**Option 2 — home-screen shortcut (fewest taps; fastest "out of head").**
1. Install the **Advanced URI** plugin in the vault.
2. Capture URI (URL-encode the vault name if it has spaces):
   `obsidian://adv-uri?vault=<YOUR_VAULT_NAME>&commandid=templater-obsidian:create-new-note-from-template`
3. Place it on the home screen with a free automation app (**Automate** or
   Tasker): add an *Open URL / Browse URL* action with that URI, then drop its
   shortcut widget on the home screen. One tap → Obsidian opens straight into a
   new draft.

#### Android caveats
- **"Commit-and-sync" may not push.** Depending on the Git plugin's
  configuration, *commit-and-sync* can commit + **pull** without pushing — so a
  captured draft is committed locally on the phone but never reaches the remote,
  and never appears on the desktop after a pull. If a mobile draft doesn't show
  up on the desktop, run the plugin's explicit **"Git: push"** on the phone (it
  may take a while, then reports the pushed file). To avoid it, confirm push is
  enabled in the commit-and-sync settings. **Symptom:** the draft is visible in
  the phone's Obsidian but absent from the synced repo.
- **Default to Editing view on mobile.** If the default new-note view is
  *Reading*, Templater folder-template code (beyond the title) may not run on
  Android. Set the default to Editing / Live Preview.
- **"Untitled" timing.** Obsidian may create the file as *Untitled* before
  prompting for a name, so `tp.file.title` can briefly be "Untitled". Harmless
  for idea-drop (the body holds the idea; triage reads the body) — rename only if
  you care.
- These are Android-storage quirks, unrelated to the desktop flow.

### Verify
Capture a throwaway draft on the phone, let it sync, and confirm on the desktop
that the resulting commit contains **only** the new file under `tasks/drafts/`
(no deletions — if you see deletions, the vault has a portability violation: run
`forge-vault-symlinks.sh check`).

If the draft never appears on the desktop at all (no new commit after a pull),
the phone likely committed but didn't push — see the *"Commit-and-sync may not
push"* caveat above. Run an explicit **"Git: push"** on the phone.

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

The wikilink resolves to the draft file in `tasks/drafts/`.

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

1. Delete the draft file from `tasks/drafts/`
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
