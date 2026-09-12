# Architecture notes

Updated: 2026-09-12

These notes describe a proposed implementation, not verified capabilities. The
product requirements are agreed; dependencies and implementation details must
be validated during milestone 0 and the sync prototype.

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

TextKit 2 rendering attributes do not participate in layout. Milestone 0 uses
a body-sized bold heading style. Larger heading metrics are deferred to
milestone 1 and will use managed text-storage attributes unless testing shows a
custom layout fragment is warranted.

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
synchronization. Ordinary Markdown files are continuously maintained derived
copies in user-visible local storage, with no import of subsequent external
changes in the first version.

- Save locally without waiting for network access. Define when an edit is
  considered durably saved.
- Persist document state and pending sync work consistently; a crash must not
  leave a saved edit permanently absent from the upload queue.
- Write Markdown atomically where supported and track incomplete
  materialization so it can be retried on restart.
- Keep managed copies outside iCloud Drive to avoid overlapping synchronization
  systems.
- On macOS, use a user-selected local folder and retain access with a
  security-scoped bookmark. Handle moved, missing, and inaccessible folders.
- On iPhone and iPad, keep the projection in the app's Documents directory and
  expose it through Files.
- Detect external changes before replacing a projection. Do not silently
  import them or destroy the externally changed content; define the exact
  warning and recovery behavior before implementing the writer.

Markdown copies are not independent backups. In particular, an iOS or iPadOS
Documents directory can be removed when the app is uninstalled. Provide an
explicit full-library export to an independently chosen location. Maintain
recovery versions separately from the latest projection. Do not silently
discard CRDT state and create new identities when recovery is needed.

## Proposed synchronization

Start by evaluating Automerge Swift for merging document edits and CKSyncEngine
against a CloudKit private database for transport. A custom server and a
generic public sync library are outside the initial scope.

Application-level end-to-end encryption is not required initially. Rely on the
CloudKit private database and normal platform data protection for the first
version; revisit encryption only through a later explicit product decision.

- Use stable note identities independent of filenames. Determine the
  folder/metadata representation before milestone 3.
- Store pending changes durably, and handle duplicate delivery idempotently.
- Evaluate immutable change bundles and snapshots. Retain history initially; do
  not delete old changes before defining safe recovery for long-offline
  devices.
- Treat CloudKit scheduling and CRDT merging as separate concerns. Measure
  handoff latency and provide understandable pending/error states.

Prefer direct edit operations when practical. If whole-string diffing is used
in the prototype, evaluate its performance and concurrent-edit behavior before
making it the permanent editor interface.

## Decisions still to resolve

- Local storage format, transaction boundaries, Markdown-write recovery,
  external-change recovery, and revision retention.
- Note/folder metadata schema, filename collisions, and delete-versus-edit
  semantics.
- CloudKit record layout, snapshot discovery, initial download, and history
  growth.

Resolve these when needed by the milestones. Keep this document aligned with
the implemented design and explain the reasons for material changes.
