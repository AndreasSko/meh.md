# Device-local Recents and navigation

Wave 1 adds five recently edited notes above the file tree. Only a local
content edit promotes its stable note ID. Opening a note remembers it for
relaunch without adding or reordering Recents. A local rename also
counts as activity, without selecting a sibling renamed from the sidebar.
Incoming sync, background preview loads, and moves do not change that order.
The preview comes from the current session and is never stored in preferences.

Recents, the file tree, Trash, and folder expansion preferences stay on this
device. A notebook-scoped UserDefaults record also stores its last active note
and per-note native selection and reading positions. These values never enter
the Automerge catalog, cloud records, or managed Markdown copies.

## Navigation ownership

Each NotebookView owns a small NotebookNavigationState instance containing
its selected ID and session. The existing serialized navigation operation
commits the native buffer and flushes the current session before installing a
successfully opened replacement. Failed commits, saves, and unfinished native
composition retain the current editor. This establishes a scene-local boundary;
it does not enable multiple windows or define a multi-window preference policy.

A restored note does not automatically take keyboard focus. New Note focuses
its title; Return saves the title and focuses the body. Clicking the body also
saves the title, preserving the clicked caret. No title action buttons are
needed. Restored selections use composed-character-safe
UTF-16 ranges, with a visible-text anchor and vertical offset for reading.
Activation waits for the incoming native editor to attach; replacing it cancels
any pending activation of the outgoing editor.
Restoration waits for native layout and composition, clamps positions when the
content has changed, and does not rewrite source or create undo entries.
Positions are captured when leaving a note, leaving the scene, and on normal
application termination. They are approximate after substantial remote edits;
there is no promise to recover the exact old passage after it was deleted.

## Missing and trashed notes

Rename and move preserve note identity and saved position. Trash removes a
note from Recents and from automatic restoration. A deliberately opened Trash
note remains editable under the existing Trash rules. Remote deletion leaves
an already owned session available for the existing terminal/unavailable UI;
it does not silently replace an editor buffer. Explicit permanent deletion
clears the selected session only after the guarded navigation/save operation.

A failed last-note load falls back to the browser with an unavailable message.
Missing previews show an unavailable label. Corrupt preference data is ignored;
notebook contents and their recovery files remain authoritative.

## Verification

Model regressions cover the five-note limit, explicit local activity, live
remote preview updates without reordering, stable identity, Trash and permanent
deletion, notebook scoping, corrupt preferences, and persisted expansion state.
Native editor checks cover selection/viewport round trips, Unicode clamping,
composition deferral, and source/undo preservation. Mac, iPhone simulator, and
iPad simulator UI checks use fictional notes for Recents, collapse persistence,
and last-note restoration. Mac keyboard checks also exercise caret restoration
through note switching and normal quit/relaunch.

Simulator results do not establish physical iPhone/iPad or iCloud acceptance.
Heading outlines, focus mode, pinned notes, and multi-window behavior remain
outside this delivery.
