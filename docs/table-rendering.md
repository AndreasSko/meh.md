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
Markdown editing; precise caret placement within rendered cells and table
creation/row/column commands belong to subsequent work.

## Correctness checks

The native editor tests cover parser ranges, cell-local inline syntax,
incremental invalidation, whole-table source reveal, narrow/uneven fallback,
wrapping, alignment, font/width changes, byte preservation, undo, and remote
replacement. Visual checks use fictional content in an isolated app preview
notebook and a disposable native-editor harness. The iPhone app test taps
into a table
and verifies that typing still edits the original Markdown.
