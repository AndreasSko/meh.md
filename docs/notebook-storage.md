# Notebook storage

Settings > Storage shows the sizes of saved files for the current notebook on
this device. The overview includes active and trashed notes, a category bar,
percentages, and the five largest notes. Show All opens the full list ordered
by size; each note has a detail view and active notes can be opened directly.

The total uses logical regular-file sizes, before filesystem compression. It
does not measure the installed app, RAM, iCloud quota, or unique physical disk
blocks. Device storage settings can therefore show a different number.

## Accounting

Only the active workspace's notebook directory, Markdown-copy directory, and
backup directory are scanned within the app's trusted container. Other
notebooks, imported files elsewhere in Documents, and other preview runs are
excluded. Hidden staging files count;
symbolic links are not followed. Missing directories are empty, while read
errors fail the measurement instead of presenting incomplete totals.

| Category | Files counted |
| --- | --- |
| Notes & History | Current saved files for catalog notes, including Trash |
| Recovery Copies | Previous files and retained note/catalog quarantines |
| Markdown Copies | All regular files under Notebook Copies |
| Backups | All regular files under Backups |
| Other Notebook Files | Catalog, sync state, orphan files, and other data |

Per-note sizes include their current file and retained recovery files. Shared
Markdown copies, backups, catalog data, and sync data are counted separately.
Active-note counts exclude Trash and permanent deletions; Trash has its own
count. Orphan files contribute to the total without appearing as named notes.

The current Markdown and its history share a compressed Automerge document.
Subtracting the current Markdown's UTF-8 size would not measure history:
compressed bytes and plain text are different representations. Storage keeps
these together under Notes & History.

## Responsiveness and preservation

The workspace flushes pending edits and snapshots note names and placements.
A cancellable utility task then measures file metadata without decoding note
bodies or indexing history. Reopening Storage repeats the measurement. It is a
point-in-time estimate: saves, sync, or backups can change files during a scan.

Viewing or reopening a report preserves saved note content and history. Open
Note uses the existing presentation path, which checks that the selected note
is still active before opening it.

## iCloud copies

Cloud notebooks also show Clean Up iCloud Copies and Last Cleanup. Cleanup
removes only redundant remote sync snapshots after proving a survivor retains
their complete history. It does not clear note history or local replay data.
It receives and publishes pending changes first, then runs separately from
the sync indicator. New edits or sync requests interrupt maintenance.

Automatic cleanup is opportunistic after a successful exchange: ten eligible
copies for a document, 16 MiB of estimated redundant payloads, or a 24-hour
backstop. It stays quiet in the writing screen. Manual cleanup bypasses those
thresholds; failures appear in Storage and leave successful sync status alone.
Last Cleanup records a successfully completed pass, including a checked pass
that finds no redundant copies. Large queues can need several bounded passes.

## Clearing history later

History clearing is a separate sync design problem. Current storage rejects
replacement documents without the saved ancestry; sync also uses ancestry to
validate checkpoints and retire snapshots. Rebuilding a document locally can
leave other devices holding the old history.

A future design would need a synchronized document generation or reset,
rules for offline edits and stale devices, adoption acknowledgments, and safe
retirement of old remote snapshots. This feature does not implement pruning
or claim that ordinary Automerge compression removes history.
