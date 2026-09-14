# Notebook navigation and preview workspace

The notebook navigation from the milestone 3 stage 3 checkpoint is now the
default interface in `meh.md Local` and `meh.md iCloud Dev`.

`MEH_NOTEBOOK_PREVIEW=1` remains available in Debug builds. It opens the
separate `NotebookPreview` store under Application Support for isolated UI
work. Preview edits save locally but do not sync or update the activated
notebook's managed Markdown copies.

Normal launches use the activated notebook store. Single-note migration and
compatibility sync are no longer active. Existing notebooks remain intact.

## Behavior available for feedback

- One hierarchical sidebar contains folders and notes alongside the editor.
  Hiding it leaves the editor; compact devices open notes from the tree.
- New Note immediately opens an editable note with a date-based filename.
  Repeated creation uses a numeric suffix to avoid existing sibling names.
- Create folders from the sidebar context menu or a folder's context menu.
  Folder creation starts inline naming; cancel retains the initial folder.
- Click the title above the editor to rename a note. The Markdown extension
  is hidden and preserved; long titles wrap within the writing screen.
- Rename inline; move, trash, and restore from action menus.
- Drag a note or folder onto another folder to move it. Only IDs belonging to
  this notebook are accepted; dragging external files does not import them.
- Trash keeps content editable and preserves folder ancestry for restore.
  Children hidden by a trashed parent explain the need to restore that parent
  or move the child out. Confirmed Delete Permanently and Empty Trash are
  described in the [deletion contract](notebook-permanent-deletion.md).
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

## Wave 1 writing verification

The date-named creation and inline-title flow has a shared Mac/iPhone UI
regression using fictional observatory notes. It types without first tapping
the editor, renames through the title, checks source preservation and title
wrapping, and creates another note directly from the writing screen.

The cloud-status UI check uses a disposable localhost notebook. It verifies
manual sync in the details popover, then relaunches with an injected transport
failure and checks the paused cloud indicator without a writing-screen sync
bar. This is simulator evidence, not a physical iCloud handoff test.

The Local UI-test target now supports native macOS as well as iOS. Select the
macOS SDK explicitly when running its Mac UI tests. Physical iPhone/iPad
writing and iCloud notification delivery remain owner acceptance checks.
