# Managed Markdown copies

Status: one-way, read-only product-output policy active for the notebook.

## Activated notebook hierarchy

The activated app publishes active notes beneath
`Documents/Notebook Copies/Markdown`. Folder placement and derived display
names determine the hierarchy. A note name receives `.md` unless its catalog
name already has a Markdown suffix. Deterministic collision suffixes prevent
two catalog items from replacing one another. Trashed notes and folders are
omitted from this projection.

The `Notebook Copies` root is app-owned. A durable manifest beside `Markdown`
binds the directory to one notebook and tracks complete generations. The
publisher builds a replacement hierarchy first, then swaps it into place.
On restart it recovers an interrupted swap before publishing again. It fails
without replacing the current hierarchy if any active note snapshot is
missing or invalid. An unchanged refresh validates the managed paths and exact
file bytes, then leaves the existing hierarchy in place.

The publisher adopts only an empty root or one with its matching ownership
manifest. It does not delete or overwrite unrelated files. As with the first
copy writer, these files are product output: external edits are not imported
and can be replaced by the next complete publication.

## Earlier single-note copy

The following policy records the milestone 1 `note.md` writer. Activation
preserves those existing copies and their bookkeeping, but the notebook no
longer maintains or removes them.

### Ownership and locations

The Automerge file remains authoritative. The copy writer receives immutable
snapshots only after local persistence succeeds. Its failures do not block
editing or authoritative saves. Copy status acknowledges the latest persisted
snapshot, not an older write that happened to finish.

On Mac, the owner selects a local folder outside iCloud Drive. A persisted
security-scoped bookmark restores access. On iOS, the destination is the app's
Documents directory, exposed in Files. The stable filename is `note.md`.

An unrelated `note.md` already present when a destination is first selected is
never adopted or replaced, even if its bytes match. The owner must choose
another folder. After the app creates `note.md`, it owns that path as a managed
product output.

Private configuration and per-destination bookkeeping live under Application
Support `Notes/MarkdownCopy`. Bookkeeping records the note identity, Automerge
heads, byte fingerprint, directory identity, and a pending write's staged-file
identity. The last item distinguishes interrupted first creation from an
unrelated file with identical bytes. This is not another authoritative
document or a revision-number system.

### Replacement and recovery

Writes are serialized and coordinated with `NSFileCoordinator`. The writer
stages the latest persisted text as exact UTF-8 bytes and replaces the managed
copy. An external edit to a managed copy is overwritten on the next copy
publish, app activation, or reopen. A deleted managed copy is recreated from
the authoritative state at the same opportunities.

The app does not ingest external edits, create conflict copies, or treat the
managed Markdown file as a second editing source. Continuous file watching is
outside milestone 1. The read-only label describes the product contract; it
does not claim that operating-system permissions prevent another program from
writing the file.

A failed write leaves authoritative saving and editing available and exposes a
separate copy error for retry. Missing access, a replaced destination folder,
symlinks, and nonregular files remain errors that require reconnection or a new
destination.

External changes made after an update are corrected at the next update or
activation. Tests cover injected interruption and race boundaries, not sudden
power loss.

### Verification boundary

Writer and controller tests cover exact bytes, initial collisions, external
edits and deletion, restart, directory replacement, and newer snapshots
arriving during an older write. Signed Mac app checks passed for folder
selection, exact UTF-8 updates, bookmark restoration, external-edit overwrite,
and deleted-copy recreation. See [the evidence](local-note-verification.md).
The iPhone 17 simulator also passed save/reopen, exact copy-byte comparison,
and Files preview checks. Milestone 1 is complete; remaining device checks
are recorded in the milestone plan.
