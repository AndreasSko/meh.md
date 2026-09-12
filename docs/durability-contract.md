# Local note durability contract

Date: 2026-09-12
Scope: milestone 1's first usable single-note increment.

## Ownership and snapshots

- One main-actor editing session owns a mutable Automerge document. The app
  exposes one editing window on macOS and one scene on iOS for this increment.
- Use the existing stable UUID, schema version, and collaborative Text object.
  Validate all required fields and the supported schema version on load.
- Capture serialized bytes and the matching Automerge heads synchronously,
  without suspension or concurrent mutation. Send this immutable snapshot to
  one storage owner. Only one save request is active for a session at a time.
- New typing updates the editing session while storage is busy. When a write
  finishes, save the latest pending state next; intermediate snapshots may be
  coalesced. Neither task cancellation nor actor reentrancy may reorder writes.

## Saved status and failures

- Show saved only when current heads equal successfully persisted heads. Keep
  persisted heads in memory; derive them from the file on reopening. An
  Automerge commit is not an operating-system file flush.
- Capture and save promptly after edits, with bounded coalescing if needed.
  A pause in typing or app termination must not be the only save trigger.
- A failed save preserves the editor buffer, displays an error, and offers
  retry. Do not automatically loop on persistent disk failures. Later edits
  and explicit retry may trigger another attempt.
- Save completions update status only. They never replace text, selection,
  composition, or native undo history. Editing stays disabled during loading
  and while a recovery decision is required.

## Files and replacement

- Use the app's Application Support directory, under a `Notes` subdirectory:
  `note.automerge` and `note.previous.automerge`. No public Markdown file is
  used as an input for loading this internal state.
- Validate incoming snapshots and the current document before replacing
  either file. Keep the same evolving Automerge history across saves.
- Write new bytes to a unique temporary file in that directory and flush it.
  Stage and flush the valid current bytes as the previous file, atomically
  replace previous, then atomically replace current and flush the directory.
  Acknowledge success only after all required write/flush operations succeed.
- The initial supported guarantee covers process termination at tested write
  boundaries on local storage. `fsync` and rename tests alone do not prove
  sudden-power-loss guarantees. Do not label this as protection against all
  hardware failures. Ignore abandoned temporary files on load.

## Startup and recovery

- Both files absent means first launch; create and save an empty note. A
  missing current file with a previous file is a recovery case, not first
  launch. Unreadable or invalid existing files must never produce an empty
  note automatically.
- Load a valid supported current document. Otherwise, preserve its bytes and
  offer a valid previous document explicitly. If no supported document can be
  loaded, block editing and report the failure. An unsupported schema is a
  compatibility error, not permission to replace a newer-format document.
- After the user chooses fallback, retain damaged current bytes under a unique
  quarantine filename, restore the previous serialized state, and resume
  saving the same note. Warn that edits newer than the fallback may be lost.
  A failed recovery must leave its source available for retry.
- One previous file is storage fallback, not a user-facing version archive.
  In a healthy note, restoring old text means editing the current Automerge
  document; never replace its history with an old snapshot. A history browser
  and long-term retention policy remain outside this increment.

## Markdown copy handoff

- The copy writer will receive text and heads from a successfully persisted
  snapshot. Its success/failure is separate from authoritative save status.
- Keep its destination, last managed content fingerprint, and interrupted
  write bookkeeping outside the Automerge document. The copy's heads may be
  tracked as provenance; they cannot detect external file edits.
- Reconcile the actual copy on restart before overwriting it. Missing or
  unexpected bytes and a crash between copy replacement and bookkeeping need
  explicit handling in step 6; no speculative queue is added now.

## Evidence required for the usable slice

- History survives repeated save/load cycles and process interruption; the
  reopened document still merges correctly with an earlier offline fork.
- Controlled slow and failed writes preserve later typing and accurate saved
  status. Missing, damaged, unsupported, and fallback states are distinct.
- Actual native adapters deliver typing and undo/redo automatically through
  the document binding. Exercise marked-text completion on macOS and iOS.
- An app build can edit, save, quit, and reopen the same note on macOS and an
  iOS simulator. Physical-device observations remain separately recorded.
