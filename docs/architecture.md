# Architecture notes

Updated: 2026-09-13

These notes distinguish accepted boundaries from proposed implementation
details. Dependencies and synchronization details still require validation in
their respective milestones.

## Project identity and platforms

- Product and display name: `meh.md`.
- Bundle identifier: `de.andreas-sk.meh-md` on macOS, iOS, and iPadOS.
- Apple development team: `9YFM7J3EH3` for the app and test targets.
- Intended deployment targets: macOS 27, iOS 27, and iPadOS 27.

The existing Xcode project declares macOS 27 and iOS/iPadOS 27. A separate
toolchain and signing audit was explicitly deferred during the first editor
tranche. Successful unsigned local builds establish SDK compatibility, but do
not verify signing or real-device deployment. Reserve a CloudKit container
when the synchronization prototype requires it; the expected identifier is
`iCloud.de.andreas-sk.meh-md`.

## Proposed structure

- **Native app interface:** Navigation, folders, note selection, editor, and
  sync status.
- **Shared document core:** Stable identities, note text, metadata, and edit
  operations.
- **Local persistence:** Durable document state, pending sync work, and
  recovery versions.
- **Markdown writer:** Maintain portable files and folder structure from saved
  state.
- **CloudKit transport:** Transfer document changes and report synchronization
  events.

Use SwiftUI for the application interface. Keep the editable text surface as a
thin AppKit/UIKit adapter, sharing syntax detection and document behavior
across platforms. The editor spike found that SwiftUI's attributed
`TextEditor` creates a formatting-only undo step when derived Markdown styles
are refreshed. Native text views expose the hooks needed to avoid that behavior
and to detect marked text from input methods. Both adapters select TextKit 2
explicitly. Paint-only presentation uses rendering attributes; fonts that
affect layout use text-storage attributes with undo registration suppressed.
The no-extra-step result has been observed on macOS, and the owner has tested
editing and undo on a physical iPhone. iPadOS interaction checks remain open.

## Editor

Keep the backing text as literal Markdown. Apply visual styling without
replacing source sequences with attachment characters. This matches the initial
visible-syntax requirement and should simplify mapping edits to document
operations.

TextKit 2 rendering attributes do not participate in layout. Milestone 1 adds
larger heading metrics through managed, undo-suppressed text-storage
attributes. Paint-only styles continue to use rendering attributes.

Investigate FSNotes as an implementation reference and possible source of
selectively reusable code, not as an assumed drop-in editor dependency. Check
dependencies, text-index handling, and licensing before copying anything.

The initial investigation found that FSNotes is MIT licensed but that its
editor is tightly coupled to application services. Some paths replace Markdown
with attachments and some range calculations mix native UTF-16 offsets with
Swift character counts. The current independent native spike therefore uses
FSNotes only as a behavioral reference. See
[the editor investigation](editor-investigation.md) for evidence and deferred
risks and [the editor decision](decisions/001-native-text-editor.md) for the
accepted direction.

Explicitly test the relationship between native text ranges, Swift strings, and
the chosen Automerge text encoding. Selection, input-method composition, and
undo must not be broken by styling or remote updates.

## Local persistence and Markdown copies

The internal document state is authoritative for in-app editing and
synchronization. Ordinary Markdown files are managed, one-way product outputs
in user-visible local storage. The activated notebook does not ingest external
changes to these managed Markdown copies.

The shared document core owns stable note identity, literal Markdown text,
metadata, and edit application. Native editor adapters do not persist data.
The local store and Markdown writer sit behind the core, and future sync must
use the same boundary. This is recorded in
[ADR 002](decisions/002-document-persistence-boundary.md).

The owner-approved milestone 1 sequence began with a local Automerge spike.
The [spike](automerge-spike.md) supports the direction of Automerge files
in internal Application Support storage, with a previous known-good file for
recovery. Maintain the ordinary UTF-8 Markdown copy separately. No SQLite
database or custom journal is planned. This brings local Automerge use forward
from milestone 2 without changing ADR 002's document boundary; CloudKit
remains in milestone 2. See the [execution plan](milestone-1-plan.md).

The spike established scalar Automerge text, UTF-16 conversion, local merge
behavior, and history through file interruption. Real adapter probes pass
after a scoped macOS UndoManager callback correction. `Sources/NoteCore` now
implements the session and serialized file storage. The
[durability contract](durability-contract.md) uses Automerge heads for saved
state and defines recovery behavior. Separate file writes are not one atomic
transaction. Markdown materialization uses the approved
[copy contract](markdown-copy-contract.md).

- Save locally without waiting for network access. Define when an edit is
  considered durably saved.
- In milestone 2, persist document state and pending sync work consistently;
  a crash must not leave a saved edit permanently absent from upload discovery.
- Write Markdown atomically where supported and track incomplete
  materialization so it can be retried on restart.
- Keep managed copies outside iCloud Drive to avoid overlapping synchronization
  systems.
- On macOS, use a user-selected local folder and retain access with a
  security-scoped bookmark. Handle moved, missing, and inaccessible folders.
- The notebook writes active notes beneath
  `Documents/Notebook Copies/Markdown` and exposes that hierarchy through
  Files. Trashed notes are omitted.
- Protect an unrelated `note.md` when a destination is first selected. Once
  the app creates its managed copy, replace external edits on the next publish,
  activation, or reopen, and recreate deletions. Do not ingest external edits
  or create conflict copies.

Earlier single-note copies remain where they were created, but activation no
longer maintains them. Markdown copies are not independent backups. In
particular, an iOS or iPadOS Documents directory can be removed when the app
is uninstalled. Provide an explicit full-library export to an independently
chosen location. Maintain
recovery versions separately from the latest projection. Do not silently
discard CRDT state and create new identities when recovery is needed.

## Synchronization prototype

Milestone 1 validated Automerge Swift locally, including merges between test
replicas without network transport. Milestone 2 adds a shared synchronization
coordinator over a small record-store transport interface. An in-process test
store and a persistent localhost HTTP service exercise the same production
merge/save path. The CloudKit adapter uses CKSyncEngine in a private database;
real iCloud behavior remains subject to signed-device validation. The localhost
service is a development tool, not a hosted product backend.

Records contain immutable full-history Automerge snapshots, addressed by their
SHA-256 digest. Bootstrap chooses a canonical seed atomically. A fresh client
persists its proposal before sending it, so losing the response cannot create
a second local identity. Existing independent notes are preserved and produce
an explicit identity conflict rather than being silently combined.

The coordinator saves merged downloads before advancing its cursor, and
compares cursor/acknowledgment checkpoints with local history on reopening.
Restoring an older local file therefore triggers replay. Upload discovery uses
the persisted document; it does not depend on a transient notification.

CloudKit fetched assets are retained in a durable inbox before engine progress
is persisted. A failed inbox commit stops that adapter instance from saving
later engine tokens. Inbox cursors include a persisted generation identifier
so a rebuilt inbox cannot silently reuse an old offset. The initial adapter
uses manual engine exchanges requested by the foreground app and explicit
retry. Background/push scheduling remains a separate acceptance item.

Notebook activation retains foreground polling. A fresh iCloud installation
first joins the canonical version 1 note online, then activates its isolated
version 2 catalog and note records. Existing activated notebooks open from
local state while offline. The bridge imports later version 1 edits one way;
it does not publish notebook changes into the old note.

Native editor views retain the revision they actually display. A committed
whole-text edit updates a branch at that revision and merges it into the live
document, retaining remote edits received during composition. Remote buffer
replacement clears stale native undo/redo entries; subsequent local editing
builds a new undo history. Failed native commits retain their visible buffer.

Application-level end-to-end encryption is not required initially. Rely on the
CloudKit private database and normal platform data protection for the first
version; revisit encryption only through a later explicit product decision.

- Use stable note identities independent of filenames. Determine the
  folder/metadata representation before milestone 3.
- Store pending changes durably, and handle duplicate delivery idempotently.
- Exchange immutable full-history snapshots initially. Retain history; do
  not delete old changes before defining safe recovery for long-offline
  devices.
- Treat CloudKit scheduling and CRDT merging as separate concerns. Measure
  handoff latency and provide understandable pending/error states.

Prefer direct edit operations when practical. If whole-string diffing is used
in the prototype, evaluate its performance and concurrent-edit behavior before
making it the permanent editor interface.

## Decisions still to resolve

- Durable-save acknowledgment and local fallback recovery are implemented.
  The one-way Markdown-copy ownership policy is accepted. A user-facing
  history retention policy remains separate work.
- Full-library import is implemented and tested. Permanent content cleanup
  and explicit export remain separate work.
- Signed notebook CloudKit delivery, fresh-device download, account
  transitions, background scheduling, and the cost of retained snapshot
  history.

Resolve these when needed by the milestones. Keep this document aligned with
the implemented design and explain the reasons for material changes.
