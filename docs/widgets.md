# Widgets

The meh.md widget puts notes on the Home Screen, the iPad Home Screen and
the Mac desktop. Tapping a note opens it in the app; the yellow + in the
corner starts a new note in the default New Note folder, like the app's own
+ button.

## What a widget shows

Long-press the widget and choose Edit Widget to pick what it shows:

- **Recents** (default): the same order as the app's Recents, pins first,
  then the most recently edited notes. Small and medium widgets show three
  titles with the time of the last change. Large shows five notes with the
  same excerpt as the app. Extra large (iPad and Mac only) shows pins on
  the left and recent notes on the right. *Pinned Only* drops the recent
  notes. Each row opens its note.
- **One Note**: the start of a single note, drawn like Live Preview with
  checklists, bullets, highlights and links. The picker lists pinned and
  recent notes first; search finds any other note. Tapping the widget opens
  that note.

The widget follows the paper, the chosen highlighter and ink, and dark mode.
Recents leaves out hidden and trashed notes, as in the app. The One Note
picker offers every note outside Trash, including notes hidden from Recents,
because picking one is a deliberate choice. Note titles and text are marked
private, so the system can redact them while the device is locked.

## How the widget gets its notes

Widgets run in their own process and cannot open the notebook. The app
writes a small copy of what widgets need into a shared App Group folder:
every note's title and folder for the picker, the Recents order, and the
first 1,200 characters of each recent note. It writes the copy after the
catalog changes, two seconds after typing pauses, and when the app leaves
the foreground or, on the Mac, loses focus. On iOS it asks for a moment of
background time so that last write finishes. It reloads widgets only when
the copy changed, which keeps within the system's widget refresh budget.
The time labels refresh on their own, from a timeline the widget plans
ahead.

A One Note widget for a note outside Recents has no content in the copy at
first. The widget then asks for it through a request file in the same
folder, and shows "Open meh.md to show this note here." The next time the
app writes the copy, it includes that note. The file keeps the eight newest
requests; a widget whose note drops out simply asks again.

Widget links use the `mehmd://note/<UUID>` and `mehmd://new` URLs. The
system hands widget links to the app that owns the widget, so the scheme is
not registered with the system. Links go through the same request queue as
Home Screen quick actions, so they work while the app is starting.
The window that receives a link handles it; on the Mac, links go to an open
window instead of a new one. Opening a note closes Settings, Trash,
Templates, Quick Open, Backlinks and search first.

Each build has its own App Group, so the iCloud Dev app's widgets never
show the release app's notes:

| Build | App Group |
| --- | --- |
| Release and Local | `group.de.andreas-sk.meh-md` |
| iCloud Dev | `group.de.andreas-sk.meh-md.icloud-dev` |

The `MEH_APP_GROUP` build setting sets the group in the entitlements and
in each Info.plist, where `MehWidgetStore` reads it.

## Code

`MehWidgetData` is a small Swift package target shared by the app and the
widget: the copy's format, the store, the links, the time labels and the
Markdown blocks the widget draws. It does not link NoteCore, so the widget
stays well within the extension memory limit. The app side is
`NotebookWidgetSnapshotWriter`; the widget lives in `meh.mdWidgets/`.
`MehWidgetDataTests` covers the shared code.
