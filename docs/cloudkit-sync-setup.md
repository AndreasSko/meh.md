# CloudKit synchronization setup

The CloudKit adapter targets the private database in
`iCloud.de.andreas-sk.meh-md`. The notebook uses the isolated version 2 zone
for its catalog and note snapshots; legacy version 1 joining is no longer
active. Records contain immutable full-history Automerge snapshots in `CKAsset`
payloads. Confirmed permanent deletion removes remote note snapshots after the
catalog markers are acknowledged; general history compaction is separate work.

The app target includes CloudKit entitlements for macOS and iOS with this
container selected. Xcode automatic provisioning successfully signed the Mac
Debug build for team `9YFM7J3EH3`; its embedded profile authorizes the
container. Debug and Debug-iCloud select Development; Release selects
Production. The shared `meh.md iCloud Dev` scheme enables iCloud at build time
and uses a separate app identity. See [development
builds](development-builds.md).

An active Apple Developer Program membership and valid signing assets are
required. A signed physical iPhone round trip has also passed. An iPad run
remains open. Unit tests do not create a container or deploy a production
schema.

See [live verification](icloud-live-verification.md) for the isolated Mac smoke
check and historical single-note evidence.

The iCloud Dev configuration includes APNs entitlements and the iOS remote
notification background mode for [automatic sync](notebook-sync-scheduling.md).
Physical-device delivery still needs separate verification.

Create a notebook transport with its own Application Support state directory.
The app enables automatic scheduling by default:

```swift
let notebookTransport = try await CloudKitSyncTransport.makeNotebook(
    containerIdentifier: "iCloud.de.andreas-sk.meh-md",
    stateDirectory: notebookSyncStateDirectory,
    automaticallySync: true
)
```

The iCloud Dev scheme needs no launch variables. A fresh installation must be
online to join the canonical version 2 notebook; setup failure offers a retry.
An established activated notebook opens before account discovery completes and
remains editable offline. The Local scheme uses its local notebook by default;
its legacy Debug `MEH_SYNC_CLOUDKIT=1` override remains available for targeted
tests. Use the isolated iCloud Dev scheme for manual cross-device testing.

Factory creation binds persisted transport state to the current iCloud user
record ID. Every bootstrap, fetch, and publish checks that binding again. An
account switch pauses sync with `SyncError.scopeChanged`; persisted data is not
erased or uploaded to the new account.

`CKSyncEngine` automatic scheduling complements explicit app exchanges. Manual
test workflows can disable it with `MEH_SYNC_AUTOMATIC=0`. A publish returns
only after the requested immutable record appears in a sent-record
acknowledgement. Fetch waits for a manual engine fetch, then pages records from
a durable local inbox. Delegate events are serial. Fetched assets are copied
before the delegate returns, and a following state serialization is stored with
the inbox state using an atomic replacement and file-system flush. This
preserves replay data before advancing the engine change token.

Each durable inbox has a generation UUID included in its page cursor. If the
inbox is rebuilt, the coordinator rejects the old cursor and replays instead of
skipping records at an offset that now means something different.

Unit tests cover durable inbox replay, duplicate delivery, cursor validation,
and account binding without contacting iCloud. Earlier signed Mac and iPhone
round trips passed for the version 1 single-note app. A signed Mac notebook
launch also joined the then-canonical note and synced a newly created folder.
Cross-device physical notebook delivery and physical iPad behavior remain
unverified. Other open checks include actual notification delivery, offline
handoff, account changes, and server conflicts.

## Throttling

Automatic or explicit exchanges do not override Apple's retry deadlines. The
adapter persists the longest active retry-after delay, including per-record
errors, and waits before making further requests. A small availability-only
file also gates account discovery after app restart; it is never used as proof
of account identity. Pending snapshots remain durable throughout the cooldown.
If Apple reports throttling or service unavailability without a usable delay,
the adapter waits 30 seconds. A failed cooldown write stops further requests
until the adapter is recreated from durable state.

Tests cover nested retry metadata, fallback delays, deadline persistence,
pending uploads, and startup gating with a simulated clock. They do not
intentionally trigger Apple's real quota or throttling mechanisms. See
[automatic scheduling](notebook-sync-scheduling.md) and
[batching](notebook-sync-progress.md) for the implemented notebook behavior.
