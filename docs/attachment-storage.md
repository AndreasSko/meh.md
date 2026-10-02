# Attachments

Attachments are ordinary notebook items beside Markdown notes, in any folder.
Their names, parents, ordering, and Trash state belong to the Automerge
catalog. Their bytes stay outside Automerge and JSON import journals.

## Import and organization

The file picker accepts Markdown and other regular files together. Markdown
becomes editable notes; other files become immutable attachments. Import
coordinates access to file-provider sources and copies attachments into the
notebook while source access is available. An attachment import confirmation
shows note and file counts; Markdown-only selections import directly.
Resuming a prepared import does not need its original source files.

Attachments support rename, move, manual ordering, Trash, restore, and
permanent deletion. They can be selected from Files and previewed with Quick
Look or shared/exported through the system share sheet. Preview and sharing
use a verified copy with the displayed filename and extension. Selecting a
remote attachment requests its download; downloaded content remains available
offline. Markdown export, Markdown copies, and Markdown backups continue to
contain Markdown only. Export individual attachments from their detail view.

The catalog upgrades from schema 1 to schema 2 when its first attachment is
added. Schema 2 stores the attachment UUID, SHA-256 digest, and byte count
alongside the normal item fields. Devices running the prerequisite pause
sync until updated to a compatible reader. No migration of existing Markdown
documents or their history is needed.

### Older-client compatibility

This release depends on the [upgrade safety prerequisite][upgrade]. Deploy its
optional CloudKit fields and install the prerequisite on every participating
device before enabling attachments. The prerequisite retains format 1 while
introducing the reader requirement and conditional publication boundary.

The first attachment creates a format 2 catalog locally. Its remote
publication atomically updates the canonical requirement with that catalog
snapshot. A competing writer must re-read the accepted requirement; only one
operation accepts the format transition. Compatible devices can then merge
and publish their independently prepared changes.

A device running the prerequisite pauses foreground and background sync with
**Update required**. Its existing notes remain editable, and pending changes
and history stay local. After updating to this release, it merges format 2
and publishes those retained edits. Receiving a future unsupported format
also pauses attachment work without clearing transfer progress.

Apps released before the prerequisite cannot gain this behavior remotely.
They ignore the control fields and may still publish queued format 1 records.
A new installation using an older reader cannot download a format 2 notebook.
Downgrading after saving format 2 locally cannot restore format 1 readability.
Do not rewrite a format 2 history's version register to claim compatibility.

[upgrade]: notebook-upgrade-safety.md

## Local storage and durability

Each immutable attachment uses `attachments/<UUID>/content` and a small
`manifest.json` beneath the notebook directory. The manifest has its own
format version. Unknown formats fail without replacing existing data. Equal
bytes imported as separate items keep separate identities and storage, making
deletion independent of other items.

`NotebookAttachmentStore` copies and hashes files in 64 KiB chunks. It rejects
symbolic links and nonregular files, and detects source identity, size, or
modification-time changes during copying. Content and metadata are synced to
disk in a staging directory before exclusive publication. A retry with the
same UUID verifies existing bytes and repeats durability steps. Different
bytes for that UUID fail without overwriting the saved item.

Downloads must match the catalog checksum and byte count before publication.
Export also streams, verifies, and publishes without replacing a destination.
This bounds memory use, but uploads, downloads, and previews need temporary
disk space in addition to the stored file. Cancellation and ordinary errors
remove operation-owned staging files. A process crash can leave staging or
preview copies; automatic orphan reclamation is not implemented. Such copies
are never treated as saved attachments.

## CloudKit transfers

Catalog references synchronize through the existing notebook transport.
Attachment bytes use file-backed `CKAsset` records in a separate private
CloudKit zone. There is no second iCloud Drive folder synchronization system.
See [CloudKit setup](cloudkit-sync-setup.md) for record and zone definitions.

`NotebookAttachmentSyncCoordinator` persists transfer progress separately from
Markdown sync. It permits one upload and one requested download at a time.
Missing local bytes are normal: receiving metadata does not automatically
download every file. Explicit download requests survive restart, and accepted
bytes are durable before the download is acknowledged. Upload retries verify
an existing remote asset after a lost acknowledgement.

Transient failures retry with backoff. CloudKit retry-after deadlines survive
restart and cannot be bypassed by manual retry. A file transfer failure does
not block Markdown exchange. The sync detail screen reports file activity and
errors separately and offers a retry action. Transfers use the notebook's
bound iCloud account; switching accounts pauses them. The local HTTP test
service does not implement attachment transfers; tests use a file-backed
in-memory attachment service alongside the metadata transport.

Permanent deletion removes local content and item-specific transfer/preview
copies. Remote cleanup waits until the catalog deletion is acknowledged, then
replaces the asset with a tombstone at the same remote identity. Conditional
writes prevent delayed uploads from resurrecting a deleted attachment. Trash
alone retains content. See the
[permanent deletion contract](notebook-permanent-deletion.md).

## Scope and release checks

Imported contents are immutable. External editing, replacing file contents,
binary merge histories, automatic cache eviction, and resumable chunk-level
transfers are separate future work. Transfers run while the app has execution
time; this does not promise completion after iOS suspends or terminates it.

Automated tests cover a streamed 200 MiB round trip, interrupted writes,
conflicting identities, corrupt data, mixed imports, missing source files,
metadata arriving before bytes, on-demand download, restart, lost upload
acknowledgements, server throttling, account-scope isolation, and deletion.
CloudKit record tests validate the envelope without contacting the service.
Fault injection is not a physical power-loss test.

Apple's [native CloudKit asset guidance][asset-limits] states that one asset
can contain up to 50 GB, subject to the user's available iCloud storage.
This implementation preserves local files when quota or transfer errors occur.
The archived Web Services 50 MB limit describes a different API.

[asset-limits]: https://developer.apple.com/forums/thread/827897

The macOS and iOS Simulator builds and local tests do not establish live
CloudKit delivery or a production attachment-size guarantee. Before release,
deploy the new record schema to Production and verify large-file transfers,
interruption/relaunch, on-demand preview, and deletion on actual devices using
the same iCloud account. No Production schema deployment or live cross-device
CloudKit test has been performed for this implementation.

Validation on 2026-09-26: the full Swift suite ran 615 tests with zero failures
and five existing skips. Unsigned macOS and iOS Simulator app builds passed.
An isolated iPhone simulator UI test imported a fictional note/PDF fixture,
opened the attachment detail, and presented Quick Look. Actual screenshots
confirmed that the PDF rendered. These checks used local files and the test
transport; they did not contact the live attachment CloudKit service.

Rebase validation on 2026-10-02: integrated main at `d6f656f`, resolved the
conflicts while preserving current import destinations, links, recents, and
sync safeguards. The full Swift suite ran 913 tests with zero failures and
nine skips. iCloud Dev builds passed for macOS and generic iOS Simulator.
Attachment transfers now also stop when local storage reset is scheduled.
Folder import retains one coordinated read throughout its recursive walk and
streamed attachment copies. A failed scan removes files it already staged.
The isolated iCloud Dev iPhone simulator test passed after integrating
attachments with the current compact navigation stack. Screenshots confirmed
the fictional PDF rendered; the test dismissed Quick Look, returned to Files,
and reopened the Markdown note. Quick Look exposes its controls before the
document finishes loading, so the capture test allows a bounded settling time.
This is local simulator evidence, not live cross-device CloudKit acceptance.

Prerequisite integration validation on 2026-10-02: rebased onto upgrade safety
PR #186 and main at `0aee43d`. The full Swift suite ran 978 tests with zero
failures and nine existing skips. Integration tests cover competing format 2
publications, a lost upgrade acknowledgement, an older client's retained
offline edits, and resuming after updating. The isolated iCloud Dev iPhone
simulator test again opened a rendered PDF, returned to Files, and opened its
neighboring Markdown note. Final iCloud Dev macOS and generic iOS Simulator
builds passed. This remains local and simulated service evidence; the live
CloudKit release checks above are still required.

Simulator upgrade follow-up on 2026-10-02 verified an actual format 1 app
pausing after the other simulator imported a PDF, retaining edited and new
notes through restart, and publishing both after an update that preserved app
data. The other simulator received their exact Markdown bodies. The final
Swift suite passed 980 tests with nine existing skips and zero failures.
See [the prerequisite verification](notebook-upgrade-safety.md) for evidence
and the remaining CloudKit acceptance boundary. The HTTP service transferred
attachment metadata; attachment bytes remain outside that test service.
