# Notebook navigation preview

Milestone 3 stage 3 has an opt-in UI checkpoint before full app activation.
Enable `MEH_NOTEBOOK_PREVIEW=1` in the Debug `meh.md Local` scheme to try it.
An explicit sync configuration or the iCloud Dev build retains the existing
workspace. Normal launches also retain the existing single-note workspace.

The preview copies the legacy note into a separate `NotebookPreview` store
under Application Support. It preserves the legacy files and existing
Markdown copies. Preview edits save locally but do not sync or update managed
Markdown copies. Do not use the preview as the primary notebook yet.

## Behavior available for feedback

- One hierarchical sidebar contains folders and notes alongside the editor.
  Hiding it leaves the editor; compact devices open notes from the tree.
- Create notes/folders from the toolbar or a folder's context menu. Creation
  immediately saves an untitled item and starts inline naming. Cancel keeps
  the initial name, so an item is never silently deleted.
- New note names receive `.md` unless `.md` or `.markdown` is already present.
- Rename inline; move, trash, and restore from action menus.
- Drag a note or folder onto another folder to move it. Only IDs belonging to
  this notebook are accepted; dragging external files does not import them.
- Trash keeps content editable and preserves folder ancestry for restore.
  Children hidden by a trashed parent explain the need to restore that parent
  or move the child out. No permanent-delete controls are exposed.
- Moving a selected note follows its resulting placement. Navigation flushes
  the current editor before replacing it; failed saves keep it open.
- Unfinished native composition blocks navigation. The native buffer commits
  synchronously and freezes during asynchronous operations to prevent typing
  after the last checked save.

## Checkpoint validation

Local Mac and generic iOS Simulator builds pass. All 26 Mac native-editor
regressions pass, including four navigation guard tests for commit ordering,
failed commits, marked text, and resuming editing.

Manual Mac checks created a note and folder, entered Unicode text, relaunched
and verified its contents, moved the note into the folder, trashed it, and
restored it to the original folder. The revised single-sidebar layout was
visually inspected, including the full-width editor with the sidebar hidden.
Context creation, inline naming, and automatic `.md` suffixes were checked.
The owner confirmed a note could be dragged into a nested folder after the
list container was replaced with a scrolling tree.

On the iPhone simulator, note selection opens the editor directly and Back
returns to the tree. Inline creation stays in the tree; accepting a name
persists its `.md` suffix. iPad interaction, touch drag-and-drop, and physical
input-device acceptance remain unverified.

Next, finish sync/copy activation,
recovery presentation, and compact-device interaction checks before replacing
the existing app workspace.
