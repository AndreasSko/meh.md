# Create Note in Shortcuts

Shortcuts, Siri and Spotlight can add a note without leaving the current
app. Combined with Shortcuts' own Ask for Input, or by leaving Text empty so
Shortcuts asks for it, this gives a quick capture box in Control Center, on
the Action button or on the Lock Screen. The [New Note
control](widgets.md#new-note-control) opens the app instead.

## What the action does

**Create Note** takes:

- **Text**, required, with a multi-line text box when Shortcuts asks for it.
- **Name**, optional. Without one, the note gets today's date, like a new
  note in the app. A name gets ".md" the same way a rename does.

The note goes into the folder used for new notes. If a note in that folder
already has the name, the new one gets a number, as date names do:
`2026-11-12 2.md`, `Groceries 2.md`. Names the app refuses, such as one with
a "/", fail with the app's own message.

The action returns a link to the note, such as `mehmd://note/<UUID>`. Open
URLs opens the note in the app; the link can also go into another app, such
as a to-do. An open window shows the new note right away.

The action returns as soon as the note is saved on the device; it never
waits for the network. When meh.md isn't in front, nothing else would sync
the note until the app opens again, and the system may suspend the app as
soon as the action returns. So the action then starts a sync and asks for a
short background lease that lasts until no sync is left. If the lease runs
out first, the note syncs the next time the app runs. Two runs at the same
time take turns, so they never pick the same name. Errors, such as a name
with a "/", reach Shortcuts with the app's message.

## How it works

`CreateNoteIntent` lives in the app target and runs in the app's own process
(`allowedExecutionTargets: .main`), because only the app may open the
notebook. When the app isn't running, the system launches it in the
background. `NotebookWorkspace.createNote(text:name:)` then opens the
notebook first, without waiting for the first sync, and fails with the
workspace's error when the notebook can't open. `MehShortcuts` lists the
action for Siri and Spotlight.

## Links

Each build registers its own URL scheme from the `MEH_URL_SCHEME` build
setting, so a link from the iCloud Dev build never opens the release app:

| Build | Scheme |
| --- | --- |
| Release and Local | `mehmd` |
| iCloud Dev | `mehmd-dev` |

Info.plist registers the scheme and repeats it as `MehURLScheme`, which
`MehWidgetLink` reads in both the app and the widget extension. Widget links
use the same scheme. Any app or website can open these links. The worst one
can do is open a note by its ID or start an empty note, and Safari asks
before opening another app.

`NoteIntentUITests` runs the action through AppIntentsTesting on iPhone.
