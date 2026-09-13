# Notebook core contract

This is the first implementation stage of milestone 3. The running app still
uses its existing single note. Notebook replication is implemented separately;
UI integration, import, and managed-copy reconciliation follow later.

## Authoritative state

Each note retains its existing Automerge document, including its identity,
text, and history. A separate Automerge catalog stores note/folder identities,
names, parents, and trash intent. A catalog is never decoded as a note body.

Names are individual path components. Reject empty or whitespace-only names,
`.` and `..`, path separators, Unicode control characters, and components over
255 UTF-8 bytes. Preserve other spelling, punctuation, emoji, and script
format characters. Note filenames can retain their Markdown extension.

## Concurrency and placement

Rename and move are independent properties. Conflicting edits to the same
property use Automerge's deterministic winner and expose a conflict flag.
The other value remains in document history. An observed rename or move
resolves that property's outstanding conflict.

Identical sibling names never overwrite or merge entries. Compare names using
canonical Unicode normalization and case folding, retaining diacritics. The
lowest stable UUID keeps the unmodified name. Other entries receive a derived
short-ID suffix; Markdown extensions remain last. Reserve all original names
before allocating suffixes, and handle suffix collisions deterministically.
Only the derived name may be shortened to fit the filesystem byte limit.

Reject cycles requested locally. Concurrent folder moves can still form a
cycle. For display, detach the lowest UUID in each cycle to the root and flag
it for attention. Missing or invalid parents similarly produce a flagged root
placement. Keep the stored relationship and do not create repair operations
merely by reading/merging the catalog.

## Trash

Trashing never removes catalog entries or note files. A trashed folder hides
its descendants by ancestry, including children created concurrently offline.
Restoring it exposes descendants that were not individually trashed.

An individually trashed item under an active parent appears at the Trash
root. Descendants of a trashed folder keep their hierarchy inside Trash.
Original parent metadata remains available for restore. Active and Trash
roots have separate name-collision scopes.

Concurrent trash and restore favor trash. Each action records fresh intent,
even when repeating the currently visible state. A restore performed after
observing the merged trash state resolves that conflict. A note-body edit or
rename does not implicitly restore a note, and its content remains retained.
Moving a child out of a trashed ancestor can recover that child. Restoring an
individual child whose ancestor remains trashed does not restore the ancestor.
The eventual UI must explain that distinction.

## Agreed permanent deletion: later milestone 3 stages

The owner approved Delete Permanently and Empty Trash, with confirmation.
The replication core now implements durable permanent markers. User-facing
actions and actual content cleanup remain planned.

Record a permanent marker for every confirmed note/folder identity. Permanent
deletion wins over subsequent offline edits and restores of that identity.
Keep deletion IDs so an old device cannot resurrect the deleted content.

Once the deletion intent is durable, retry removal of note documents, local
recovery files, managed Markdown copies, and cloud snapshots. Other devices
clean up when they reconnect. Replayed or late uploads must not undo the
marker and must remain eligible for cleanup.

Empty Trash targets the identities included in the confirmation. A previously
unseen note created offline inside a permanently deleted folder is retained
in a recovery location, rather than being deleted without confirmation.
Do not expose these actions until both markers and content cleanup work.

## Files and migration

The catalog uses `catalog.automerge` and `catalog.previous.automerge`.
Each note uses the existing note-file store under `notes/<UUID>/`. Saves
validate identity and history before replacing an existing valid document.
The shared file-writing primitive syncs temporary data before replacement and
syncs the directory before acknowledging completion.

Corruption or missing current data with a valid previous file requires an
explicit recovery choice. Recovery retains damaged bytes and rejects stale
recovery requests. Unsupported current schemas block rather than rolling back
automatically. Stage-one tests inject failures at write/recovery boundaries.
They do not exercise process kills, sudden power loss, or physical devices.

Legacy migration records its source identity/history before copying content.
It saves the note before linking it into the catalog and records completion
in the same catalog save as that link. Retrying reuses the same identities.
New edits on branches with shared history are merged. A changed source
identity cannot silently replace the original migration source.

A completed migration stops depending on the legacy directory. Missing or
damaged destination content requires attention rather than replacement by an
old source copy. The source's current and previous files remain untouched.
Before activating migrated storage, the caller must flush and stop its
legacy session's writes.
This helper does not lock a separate running app build.

## Next boundary

The [sync contract](notebook-sync-contract.md) defines shared bootstrap,
old-build isolation, catalog/note routing, durable progress, and partial
arrival. App integration must flush and stop the legacy session before
activating the new replica. Notebook records use a separate CloudKit zone.
