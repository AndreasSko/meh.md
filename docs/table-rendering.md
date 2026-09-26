# Table rendering

Live Preview renders top-level Markdown pipe tables as a grid. Entering any
part of a table reveals the entire table's source, including inline markers.
Leaving the table renders it again. Source mode always shows Markdown.

## Supported syntax

- A header followed by a delimiter row, with matching column counts.
- Optional outer pipes, escaped pipes, empty cells, and CRLF line endings.
- Left, center, and right alignment from delimiter colons.
- Inline emphasis, code, links, highlighting, and strikethrough within cells.
- Body rows with missing cells display empty cells. Rows without pipes may
  continue a table until a blank line or another supported block begins.

This uses the GFM table syntax within the editor's existing Markdown subset;
it is not a claim of full GFM conformance. Container-nested tables stay source.
Rows with more cells than the header also stay source, so preview cannot hide
extra user content. Invalid or incomplete tables remain editable Markdown.

## Layout and editing

Columns share the available editor width and cell text wraps. Row height is
measured from the formatted cell contents at the selected editor font size.
If columns would be narrower than 52 points or three font-size units, the
whole table stays source. There is no horizontal table scrolling in this
version. Large fonts and narrow columns can wrap individual long words.

The native text buffer retains every source character. Preview changes only
layout attributes and draws the cell content over the reserved row space.
Selection, copy, find, undo, saving, and synchronization still use source
ranges. Native accessibility continues to expose the Markdown text; semantic
VoiceOver table navigation is not added by the drawn grid.

The grid is a reading presentation. Clicking or tapping it enters ordinary
Markdown editing. Precise caret placement inside the drawn cells is not
provided. Table commands operate on the source selection, as described below.

## Table editing commands

Formatting > Table offers insertion, row and column actions, alignment, and
cell navigation. On iPhone and iPad, open More Formatting on the keyboard
accessory and choose Table. Unavailable actions are disabled.

Insert Table adds two columns and an empty body row after the current source
line (or on the current empty line), leaving existing content intact. The
first header is selected for replacement. Creation is unavailable within
code or an existing table, or when the selection crosses a table.

Place the caret inside a table cell to add rows above/below or columns
before/after it. The header cannot be deleted or have a row inserted above
it, and the final column cannot be deleted. Row/column deletion asks for
confirmation. A pending action is canceled if the text or selection changes
before confirmation, including changes received from sync.

Align Left, Center, and Right modify the selected column's delimiter.
Tab and Shift-Tab select cell contents, skipping the delimiter. Tab in the
last cell appends an empty row. Previous Cell and Next Cell offer the same
navigation on touch devices. Missing body cells are filled in when needed
for navigation. Return keeps its ordinary Markdown editing behavior.

Commands require a caret or selection within one cell of a supported table.
Selections spanning cells, nested tables, and rows with extra cells remain
manual source editing. Column actions normalize pipe spacing and delimiter
widths within that table while retaining cell contents and line endings.
Row actions change only the affected row; alignment changes the delimiter.
Each content-changing command uses the native undo and sync edit path.

## Correctness checks

The native editor tests cover parser ranges, cell-local inline syntax,
incremental invalidation, whole-table source reveal, narrow/uneven fallback,
wrapping, alignment, font/width changes, byte preservation, undo, and remote
replacement. Visual checks use fictional content in an isolated app preview
notebook and a disposable native-editor harness. The iPhone app test taps
into a table and verifies that typing still edits the original Markdown.
Editing tests also cover command availability, structural operations, cell
navigation, Unicode, CRLF, native undo/redo, and remote-update safety.
