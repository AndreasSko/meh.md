# Local notebook search

Search and Quick Open share an in-memory corpus derived from the local
notebook. Automerge remains authoritative. No index, query, or snippet is
persisted or synchronized.

## Matching and results

Search matches the displayed filename (without its Markdown extension) and
literal Markdown body. Queries are case-insensitive, accent-sensitive literal
substrings, including spaces and punctuation. Folder paths provide context;
they are not another matching field.

A single result list ranks exact title matches before title prefixes, other
title matches, and body-only matches, without separate section headings.
Ties use title, folder path, and stable note identity. Each note appears once;
spacing and separators distinguish adjacent notes. A title-and-body match
includes the body excerpt and opens the
matching passage. Title-only matches open at the beginning of the note.
An empty query offers existing Recents. Ordinary folders, including Archive,
are searched; Trash and permanently deleted notes are excluded.

Open notes contribute current session text, including unsaved edits.
Unopened notes are read from local storage without opening editor sessions or
flushing edits. Initial preparation may take time; unavailable local bodies
are counted and disclosed; their local titles remain searchable. Search does
not initiate cloud downloads.

The corpus is prepared in the background and refreshed when search needs
new catalog or body revisions. Matching and unopened Automerge decoding run
away from the main actor. Every query change starts matching immediately,
reusing in-flight preparation. Existing rows remain while replacement results
are computed; no preparation screen interrupts typing. Obsolete work cannot
publish over a newer query or notebook. A disk cache is outside this version.

## Interaction

Global search temporarily covers the existing browser so folder expansion
and browser scroll state survive cancellation. iPhone puts search and New
Note in the bottom toolbar and Settings/Trash in the app menu. Wider layouts
retain their sidebar controls and use toolbar search.

Quick Open uses Shift-Command-O and is discoverable through keyboard
commands. There is no touch menu entry. Arrow keys select; Return opens;
Escape cancels. Find in Note uses Command-F or the
note actions menu and delegates to the native AppKit/UIKit find interface.

Result navigation resolves the query against current text rather than using
cached offsets. It centers the passage in the visible editor, adjusting when
keyboard dismissal changes the viewport, without requesting editing focus or
modifying Markdown. A paint-only destination highlight remains visible
without editing focus and clears on edits or native Find. Temporary search
destinations do not overwrite ordinary
saved reading positions. Explicit editing resumes normal position tracking.

## Scope and verification

Search state belongs to the notebook scene. Replacing a replica resets its
view state; notebook/account changes clear cached results and queries.
Supported deployment targets are unchanged.

Focused tests cover ranking, literal matching, Unicode excerpts, live edits,
Trash, missing local bodies, remote updates, asynchronous query replacement,
notebook isolation, Quick Open selection, native selection, and undo safety.
Runtime UI checks and their limitations are recorded with the delivery.

## Verification on 22 September 2026

- macOS and generic iOS Simulator app builds passed.
- 36 focused core, app-model, and native-editor tests passed after feedback.
- The concurrent catalog-write/rename regression passed separately.
- iPhone simulator global-search and native-Find smoke checks passed.
- iPad simulator global-search and native-Find smoke checks passed.
- iPad Quick Open passed query entry, filtered results, and Return to open.
- A 2,000-note fictional in-memory corpus (about 2.1 KB per note) took about
  17 ms to match in one measured run. This does not measure cold preparation.
- The Mac UI harness stalled before starting a test. Unit tests and a build
  do not substitute for Mac UI acceptance or physical keyboard validation.
- A usable before screenshot was unavailable. After captures use fictional
  notes and are kept outside the repository.

## iPhone feedback refinements

Search and New Note use separate native toolbar groups. Native Find retains
UIKit's system background, as agreed after reviewing its public styling
limits. Necessary title renames wait for an active catalog write; unchanged
titles do not cause a write on navigation. Notebook errors now have readable
messages. The reported error code 3 denotes a busy notebook; the exact device
sequence has not been reproduced.

After the feedback changes, both iPhone search and native-Find smoke tests
passed again. Fictional captures confirm separate search/create controls,
the unified result list, and a visible destination highlight without the
keyboard. Quick Open is absent from the touch menu. The Mac app build passed.

The destination-centering follow-up passed eight native-editor tests and the
iOS test-target compile. Its long-note regression covers viewport resizing,
landing-position snapshots, and preservation of manual scrolling. The
iPhone global-search smoke test also passed with a long fictional note.

Final delivery checks passed 39 focused tests together. A subsequent Quick
Open regression preserves the query attached to retained results; all nine
search-state tests passed after that fix. Native editing and undo clear the
search highlight without changing undo semantics. The macOS app builds at
version 0.1.7.
