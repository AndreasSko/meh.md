# Notebook organization

The notebook stores a manual order for each folder and the root. Move opens a
folder browser; choose a location, then confirm with Move Here. The Sort Files
Once / Sort Folder Once actions apply name, creation-date, or modification-date
ordering once. Use them again to re-sort after later changes. Native dragging
remains deferred in
[issue #49](https://github.com/AndreasSko/meh.md/issues/49).
Move Up and Move Down are deliberately absent from note actions.

New and moved-in items append. Manual order can mix folders and notes. Name
and date sorts group folders first; date sorts put unknown note dates last.
Recovered display roots need an explicit move to repair their parent before
they can be reordered. Trash retains its existing display order.

## Batch operations

Use the top-right browser menu → Select Items on touch devices. The native
list supplies selection indicators. The top bar shows Select All (or Deselect
All), the selection count, and Done; the bottom bar contains only Move and
Trash. Tap the count to reveal selected items hidden in collapsed folders.
Select All includes the currently expanded Files outline, even off-screen
rows, but not collapsed descendants, Recents, or search results. Collapsing a
folder does not discard selected descendants.

On Mac, ordinary clicks open notes; Command/Shift selection keeps the editor
unchanged. Native iPad keyboard selection uses the list's selection behavior.
With the browser focused, Command-A selects the expanded outline,
Command-Shift-M opens Move, and Command-Delete trashes selected items. These
commands do not replace text-field or editor commands. Browser selection and
the open editor note remain separate. Context actions on a selected row use
the group; actions on an unselected row use that row.

The Move sheet starts at the sources' common parent (otherwise root), shows
child folders and the current path, and provides Up one level navigation.
The sheet and toolbar stay fixed while the folder list changes. Source
folders and descendants are excluded. Move Here validates again after the
editor flush and uses the existing atomic mutation. The sheet prevents repeat
submission and dismissal during saving, keeps errors and the destination for
retry, and dismisses after success. Cancel changes nothing. Choosing the
existing parent leaves order and undo history unchanged. Successful moves
reveal the destination without replacing the editor session or text undo.

Selecting both a folder and one of its descendants acts on the folder once.
The subtree stays intact. The full selection and destination are validated
before one durable catalog save; an invalid item rejects the entire action.
Batch Trash records intent without deleting Markdown source or note history.
Permanent deletion remains a separate confirmed action.

The browser menu offers Undo Move / Redo Move for the latest applicable move.
These apply compensating edits to parent and position, leaving unrelated
renames, content, and visibility changes intact. Trash recovery uses Restore
in Trash; no Undo Trash control is exposed. Moving out of Trash clears browser
undo history and is not covered by Move undo.

An undo that would overwrite newer targeted changes, revive a permanently
deleted identity, or create invalid ancestry is rejected without a save.
Unresolved preexisting move conflicts may make a move non-undoable. These
guards preserve synchronized work; no operation rewinds Automerge history.
Browser undo receipts and selection are local to the current scene.
They are cleared on restart. A repaired placement can succeed without an
undo receipt when restoring the old parent would reintroduce invalid state.

## Date portability

Known creation and content-modification dates live in the note's Automerge
document and are applied to managed file attributes where supported. Missing
dates are unknown. Markdown bodies never receive frontmatter or other
metadata. A device running an older app can still read the additive schema,
but it does not maintain the new dates or manual-order behavior when writing.

## Verification boundaries

Core tests cover atomic refusal, ancestor normalization, undo/redo, remote
changes, migration, exact source bytes, and replica convergence. Native app
builds and simulator interactions are recorded separately in the
[native browser delivery record](investigations/native-browser-selection.md).
Simulator evidence does not
establish physical iPhone or iPad acceptance.
