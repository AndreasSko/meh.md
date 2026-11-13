# Folder pages

Files is a tree, which works for finding a note by its folder but gets
tedious when sorting many notes or going several levels deep. A note's
name is often not enough to recognize it either. Folder pages treat a
folder as a place you open and look at: its notes with their first
words, or as cards that show their first lines.

## What it looks like

Tapping or clicking a folder's name in Files opens its page. The chevron
still opens the folder in place, as before.

- **iPhone:** the page is a screen in Files. Back, or the swipe from
  the left edge, returns to where the page was opened: Files' first
  screen for a folder tapped in Files, the page above for a folder
  opened on a page. A note opened from the page goes back to it.
- **iPad and Mac:** the page covers the open note on the big side.
  Close (or Escape) returns to the note exactly as it was; the note
  waits underneath, read-only. Opening a note from the page, Files or
  Recents closes the page. Files marks the folder whose page shows.

A page starts with a path line, then the folder's name. Each part of the
path opens that folder's page. On iPhone the path starts at Top Level,
which jumps back to the start from any depth; beside Files, the sidebar
already is Top Level. A path too long for one line shows its last
folders after a "…", which lists the hidden ones, Top Level included. A
note shows the same path line above its title.

The bar holds a List/Cards switch, a ⋯ menu with New Note, New Folder,
New from Template, Select and Sort, and Close beside Files. New Note,
from the ⋯ menu or the yellow button, creates the note in the folder
whose page shows. On iPhone that is the deepest page open in Files.

## List and cards

The list shows folders and notes in the folder's manual order, notes
with a preview line. Folders open their own page. Cards show notes as
small sheets with their first lines (headings, list items and tasks
without the Markdown signs) and the date they last changed, with the
folder's folders as tiles on top. Each folder keeps its choice on this
device; the list is the default. The choice does not sync.

Select, in the ⋯ menu, picks rows or cards for Move… or Trash; on the
Mac, ⌘-click selects rows too. On iPad and Mac a row or card can be
dragged onto a folder in the sidebar; a selected one takes the other
selected items with it. Swiping a row trashes it, and touching and
holding shows the same actions as in Files.

## How it works

`NotebookSceneState.pageFolderID` is the folder whose page shows. It is
separate from the open note, so neither the note's session nor its
editor changes when a page opens or closes. Beside Files, opening a page
commits the editor's text with `prepareToLeave` (which also makes it
read-only) and hides the native text view, which also takes it away from
VoiceOver and the keyboard. Close shows it again, with keyboard focus if
it had it. Switching between compact and regular width does the same. A
page whose folder goes to Trash or disappears closes.

`pageFolderIDs` lists the pages opened, and the last one shows. On
iPhone it is the path of a `NavigationStack` in Files. A folder opened
on a page goes on top; one opened from Files or a path line replaces the
list, unless it is already in it, which goes back to it. A page whose
folder disappears drops out of the list. Beside Files, the page is an
overlay on the note's screen, which keeps the bars' safe area while the
note's own geometry stays put.

On the Mac, Files' own AppKit drag tracker also watches the page: it
finds a list row by its table row and a card by its frame. Cards there
use a tap gesture instead of a Button, whose mouse tracking would keep
the drag from starting; they take keyboard focus and Space or Return
like a button.

Page rows ask the shared excerpt cache for their previews, like Recents
and Files (see [Expanded Recents](notebook-recents.md)). Cards read a
longer prefix of each note when they appear, and again only when a
saved note body changes, so typing never reloads them.

## Not included

A page has no search of its own; search covers the whole notebook as
before. XCTest still lists the hidden editor under a page, but the
accessibility containers VoiceOver walks skip it. Go Through, a mode
for filing one Inbox note after another, was left out for now.
