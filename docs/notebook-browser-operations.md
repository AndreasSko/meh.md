# Notebook organization

The notebook stores a manual order for each folder and the root. Move Up
and Move Down change sibling order; Move opens a destination picker. The
Sort action applies name, creation-date, or modification-date ordering once.
Use it again to re-sort after later changes. Native dragging is deferred in
[issue #49](https://github.com/AndreasSko/meh.md/issues/49).

New and moved-in items append. Manual order can mix folders and notes. Name
and date sorts group folders first; date sorts put unknown note dates last.
Recovered display roots need an explicit move to repair their parent before
they can be reordered. Trash retains its existing display order.

## Batch operations

Use Select to choose browser items; Command-click also toggles selection on
Mac. Selection for browser operations is separate from the note open in the
editor. Moving or trashing a selection does not replace that editor session
or its text undo stack. Recents remain local activity history, independent of
the synchronized folder order.

Selecting both a folder and one of its descendants acts on the folder once.
The subtree stays intact. The full selection and destination are validated
before one durable catalog save; an invalid item rejects the entire action.
Batch Trash records intent without deleting Markdown source or note history.
Permanent deletion remains a separate confirmed action.

Browser Undo and Redo cover the latest active-notebook Move or Trash action
and apply new compensating edits. Move undo restores parent and position,
leaving unrelated renames, content, and visibility changes intact. Trash undo
changes only visibility intent. A child's separate Trash intent survives
undoing its ancestor's Trash operation. Moving an item out of Trash clears
browser undo history and is not covered by browser undo.

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
[Wave 2 execution record](wave-2-plan.md). Simulator evidence does not
establish physical iPhone or iPad acceptance.
