---
created: <% tp.date.now("YYYY-MM-DDTHH:mm") %>
project:
type: draft
status: draft
---

# <% tp.file.title %>

<%*
// Auto-relocate to the default drafts folder UNLESS the file was already
// created inside a tasks/drafts/ folder (e.g. by an Obsidian Folder Template
// mapping for a per-project drafts folder, or by the user navigating there
// first). Without this guard, project-scoped captures would be yanked back
// to _shared. See docs/DRAFT-TASKS.md Stage 1 for the setup context.
const currentFolder = tp.file.folder(true);
if (!currentFolder.endsWith("tasks/drafts")) {
  await tp.file.move("_shared/tasks/drafts/" + tp.file.title);
}
-%>

