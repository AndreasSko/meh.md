# Table rendering

Live Preview renders top-level Markdown pipe tables as a grid. Tapping or
clicking a cell opens a native text editor inside that cell while the rest
of the table stays rendered. The active cell shows its literal inline
Markdown, including emphasis and link markers. Source mode shows the full
Markdown table.

## Supported syntax

- A header followed by a delimiter row, with matching column counts.
- Optional outer pipes, escaped pipes, empty cells, and CRLF line endings.
- Left, center, and right alignment from delimiter colons.
- Inline emphasis, code, links, highlighting, and strikethrough within cells.
- Body rows with missing cells display empty cells. Rows without pipes may
  continue a table until a blank line or another supported block begins.

This uses the GFM table syntax within the editor's existing Markdown subset;
it is not a claim of full GFM conformance. Container-nested tables stay source.
The header determines the displayed column count. Extra body cells are omitted
from the grid, as in GFM, but retained in the Markdown and available in Source
mode. Invalid or incomplete tables remain editable Markdown.

## Layout and editing

Column widths follow their formatted contents. Short values use compact
columns, while longer text gets more room and wraps at a bounded width.
Row height follows the tallest cell at the selected editor font size.

When columns cannot fit comfortably, the table keeps readable widths and
scrolls horizontally within the editor. Swipe sideways over a rendered row
on iPhone/iPad, or scroll horizontally over it with a Mac trackpad or
Shift-scroll wheel. A small indicator beneath the last row shows the
horizontal position. The rest of the note keeps its usual width and vertical
scrolling. The active cell moves with the table when scrolling sideways.

Horizontal positions are temporary view state, independent for each table.
They are clamped when the editor resizes, retained across unrelated prose
edits. Cell typing retains the current horizontal position and column widths
so the grid stays stable while rows grow to fit the edited text. Other table
changes can reset the horizontal position. Source mode, selection,
undo history, saved Markdown, and sync do not include these positions.

The native source buffer retains every Markdown character. The cell editor
forwards edits through the note's existing native undo and sync path. Only
the active cell's contents change; other cells, pipe spacing, and line endings
remain intact. Bare pipes typed or pasted into a cell are escaped, and pasted
line breaks become spaces so a paste cannot accidentally create table rows.

Caret placement, selection, copy, paste, and input-method composition use the
native cell text view. Composition candidates remain local until accepted.
Remote updates refresh or rebase the active cell; removing its row or making
the table unsupported ends cell editing. Find uses the whole note's source.
Switching back from Source to Live Preview restores the active cell when the
source selection remains within a supported cell.

VoiceOver exposes table headers and cell navigation. The active cell is the
native editable accessibility element, with its row and column information.
Selections spanning multiple cells and unsupported table structures remain
available through Source mode.

## Table editing commands

Formatting > Table offers insertion, row and column actions, alignment, and
cell navigation. On iPhone and iPad, tap the table icon on the keyboard
toolbar to insert a table directly. Inside a table, the same icon opens
a menu with labeled cell actions. Row and Column group insertion and deletion
actions in short submenus. Column Alignment shows the selected alignment.
The normal formatting buttons retain their order. Unavailable actions are
disabled.

Insert Table adds two columns and an empty body row after the current source
line (or on the current empty line), leaving existing content intact. The
first header is selected for replacement. In Live Preview on iPhone/iPad,
its native cell editor opens immediately. Creation is unavailable within
code or an existing table, or when the selection crosses a table.

Place the caret inside a table cell to add rows above/below or columns
to its left/right. The header cannot be deleted or have a row inserted above
it, and the final column cannot be deleted. Row/column deletion asks for
confirmation. A pending action is canceled if the text or selection changes
before confirmation, including changes received from sync.

Align Left, Center, and Right modify the selected column's delimiter.
Tab and Shift-Tab select cell contents, skipping the delimiter. Tab in the
last cell appends an empty row. Previous Cell and Next Cell offer the same
navigation on touch devices. Missing body cells are filled in when needed
for navigation. In a rendered cell, Return selects the next row in the same
column and appends a row when needed. Source mode retains ordinary Markdown
Return behavior. Escape returns focus to source editing. Native Undo and Redo
share the same history as the rest of the note.

Commands require a caret or selection within one cell of a supported table.
Selections spanning cells, nested tables, and selections in excess body cells
remain manual source editing. Column actions normalize pipe spacing and
delimiter widths while retaining all cell contents, including excess body
cells, and line endings.
Row actions change only the affected row; alignment changes the delimiter.
Each content-changing command uses the native undo and sync edit path.

## Correctness checks

The native editor tests cover parser ranges, cell-local inline syntax,
incremental invalidation, missing and excess body cells, adaptive widths,
horizontal offsets, wrapping, alignment, font/width changes, byte
preservation, and source-backed undo/redo. Mounted editor tests cover cell
focus, growing rows, commands, source updates, composition acceptance and
cancellation, and read-only transitions.

App UI checks use fictional content and an isolated loopback notebook in the
iCloud Dev build. iPhone checks cover native cell editing, multiline paste,
escaped pipes, Unicode, navigation, Source mode, undo, and large text sizes.
iPad checks also exercise hardware Tab, Shift-Tab, Command-Z, and the native
keyboard Undo button. Return uses native text input; simulator hardware Return
is not delivered even in ordinary Source editing.
