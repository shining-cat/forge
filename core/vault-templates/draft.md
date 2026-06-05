---
created: <% tp.date.now("YYYY-MM-DDTHH:mm") %>
project:
type: draft
status: draft
---

# <% tp.file.title %>

<%*
// Auto-relocate to the default draft folder UNLESS the file was already
// created inside a tasks/draft/ folder (e.g. by an Obsidian Folder Template
// mapping for a per-project draft folder, or by the user navigating there
// first). Without this guard, project-scoped captures would be yanked back
// to _shared. See docs/draft-tasks.md Stage 1 for the setup context.
const currentFolder = tp.file.folder(true);
if (!currentFolder.endsWith("tasks/draft")) {
  await tp.file.move("_shared/tasks/draft/" + tp.file.title);
}
-%>

