# Notebook navigation and preview workspace

The notebook navigation from the milestone 3 stage 3 checkpoint is now the
default interface in `meh.md Local` and `meh.md iCloud Dev`.

`MEH_NOTEBOOK_PREVIEW=1` remains available in Debug builds. It opens the
separate `NotebookPreview` store under Application Support for isolated UI
work. Preview edits save locally but do not sync or update the activated
notebook's managed Markdown copies.

Normal launches use the activated notebook store. Its one-way legacy bridge
imports the retained single note without changing its source files. See the
[core contract](notebook-core-contract.md) for that boundary.

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

Activation adds synchronization and structured Markdown copies around this
interface. Recovery presentation, compact-device interaction checks, live
cross-device notebook delivery, and physical iPad acceptance remain open. The
activated UI has not received a new simulator visual check; the observations
above apply to the earlier preview.
