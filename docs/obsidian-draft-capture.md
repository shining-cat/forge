# Obsidian-side draft task capture

A 5-second capture path for half-formed ideas, with zero involvement from Claude/Petra. Drafts accumulate in your vault until the weekly wrap triages them into real tasks.

## Why

The default flow — *"Petra, log this for later"* — takes 30-60 seconds of conversation that pulls focus from whatever you were doing. For genuinely small, half-formed ideas this is overhead. This setup lets you capture the idea in ~3-5 seconds without leaving Obsidian, and Petra catches up later in a structured ceremony.

The asymmetry is the point: **capture should be cheap, refinement is what Petra is good at**.

## What this is (and isn't)

- **Is:** a way to drop a one-line `draft` file into the vault from Obsidian with a single hotkey, pre-populated with timestamp + frontmatter.
- **Is not:** a replacement for the Petra-mediated flow when you're already in a Claude Code session. That flow stays as-is — you'd only reach for this when you're NOT in CC and don't want to context-switch into it.

## Setup (5 steps, one-time)

### 1. Install the Templater community plugin

Settings → Community plugins → Browse → search **Templater** → Install → Enable. Templater is a well-maintained community plugin that handles dynamic template variables (timestamps, file names, etc.).

### 2. Point Templater at your vault's template folder

Settings → Templater → **Template folder location** → set to `_templates`.

Forge's `install.sh` creates `_templates/` at the vault root and seeds it with starter templates (including `draft.md`, the one used here).

### 3. Enable Folder Templates

Settings → Templater → **Folder Templates** → toggle on.

This lets you map "creating a new file in folder X automatically applies template Y".

### 4. Map the draft folder to the draft template

Under Folder Templates, add a mapping:

| Folder | Template |
|---|---|
| `_shared/tasks/draft` | `_templates/draft.md` |

Now any new file created in `_shared/tasks/draft/` will get the draft template's frontmatter and structure injected automatically.

#### Optional — per-project capture

If you know at capture-time which project a draft belongs to, add additional Folder Template mappings for each project's draft folder:

| Folder | Template |
|---|---|
| `PERSO/forge/tasks/draft` | `_templates/draft.md` |
| `PRO/FINN/tasks/draft` | `_templates/draft.md` |
| `PERSO/SimpleHIIT/tasks/draft` | `_templates/draft.md` |
| (etc — one per project) | |

If you don't bother, just drop everything in `_shared/tasks/draft/` and the weekly triage assigns project then.

### 5. Bind a hotkey to "Create new note from template"

Settings → Hotkeys → search **Templater: Create new note from template** → bind a hotkey you'll remember (e.g. `Cmd-Shift-D` for "draft").

## Daily use

1. An idea surfaces. You're in Obsidian (or hit your Obsidian hotkey from anywhere).
2. Hit `Cmd-Shift-D` (or your bound key).
3. Templater prompts for a folder (or just defaults — depends on how you bound it). Pick `_shared/tasks/draft/` (or a project's draft folder).
4. Type a one-line title for the file.
5. The file opens with frontmatter pre-filled. Type your one-line idea below the heading. Save.

Total time: ~3-5 seconds. Zero conversation with Claude.

## What happens next

- **Drafts live** in `_shared/tasks/draft/` (or wherever you dropped them) until the weekly wrap.
- **Friday `/forge-weekly`** scans all draft folders and walks you through each one: keep / discard / defer. For "keep", you assign a project and Petra files the draft as a `[draft] refine: {title}` row in that project's BACKLOG.
- **Refinement** happens on-demand when you pick up the `refine:` row from the BACKLOG like any other task. Petra walks the standard refinement questions and produces a proper task file in `tasks/open/`; the raw draft is then deleted. Full protocol: [draft-refinement-protocol.md](draft-refinement-protocol.md).

## Petra-side awareness

You don't need to tell Petra "I have this set up". She'll mention this docs page the first time you ask her to "quick log" something in a session — and skips the mention from then on. If you explicitly say *"I know"* or *"I've set it up"*, she saves a memory and stops mentioning it across sessions.

## Notes

- Templater is a third-party plugin, NOT bundled with Forge. Forge's installer just ships the `draft.md` template + this docs page. The plugin install + Folder Template wiring is yours to maintain, same way you maintain Obsidian itself.
- The draft template at `_templates/draft.md` is A2-preserve in Forge's install policy — if you customize it, re-installing Forge won't clobber your changes (upstream version is written as a `.upstream.<ts>` sibling for visibility).
- This setup is fully optional. If you don't install Templater, the rest of Forge still works exactly as before — you just don't get the 5-second capture path.

## Related

- Forge philosophy: thin install layer over user-owned tools. Same model as superpowers (required dep, user-installed), tmux (recommended dep, user-installed). Templater follows this pattern.
- `Vault/PERSO/forge/tasks/[open|resolved]/2026-05-05-user-draft-task-capture.md` — the task that designed this feature.
