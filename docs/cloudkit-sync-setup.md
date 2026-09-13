# CloudKit synchronization setup

The CloudKit adapter targets the private database in
`iCloud.de.andreas-sk.meh-md`. The activated notebook keeps the canonical
version 1 note zone for legacy joining and uses the isolated version 2 zone
for its catalog and note snapshots. Records contain immutable full-history
Automerge snapshots in `CKAsset` payloads. The prototype does not delete or
compact remote history.

The app target includes CloudKit entitlements for macOS and iOS with this
container selected. Xcode automatic provisioning successfully signed the Mac
Debug build for team `9YFM7J3EH3`; its embedded profile authorizes the
container.
Debug and Debug-iCloud select Development; Release selects Production.
The shared `meh.md iCloud Dev` scheme enables iCloud at build time and uses
a separate app identity. See [development builds](development-builds.md).

An active Apple Developer Program membership and valid signing assets are
required. A signed physical iPhone round trip has also passed. An iPad run
remains open. Unit tests do not create a container or deploy a production
schema.

See [live verification](icloud-live-verification.md) for the isolated Mac
smoke check and its current evidence.

Enable Background Modes with Remote notifications when adding push-driven or
background synchronization. Manual foreground exchanges do not require it.

Create separate legacy and notebook transports after selecting their
Application Support state directories:

```swift
let legacyTransport = try await CloudKitSyncTransport.make(
    containerIdentifier: "iCloud.de.andreas-sk.meh-md",
    stateDirectory: legacySyncStateDirectory
)
let notebookTransport = try await CloudKitSyncTransport.makeNotebook(
    containerIdentifier: "iCloud.de.andreas-sk.meh-md",
    stateDirectory: notebookSyncStateDirectory
)
```

The iCloud Dev scheme needs no launch variables. A fresh installation must be
online to join the canonical version 1 note before activating the version 2
notebook; setup failure offers a retry. An established activated notebook
opens before account discovery completes and remains editable offline. The
Local scheme uses its local notebook by default; its legacy Debug
`MEH_SYNC_CLOUDKIT=1` override remains available for targeted tests. Use the
isolated iCloud Dev scheme for manual cross-device testing.

Factory creation binds persisted transport state to the current iCloud user
record ID. Every bootstrap, fetch, and publish checks that binding again. An
account switch pauses sync with `SyncError.scopeChanged`; persisted data is
not erased or uploaded to the new account.

`CKSyncEngine` is initialized with automatic scheduling disabled for this
bounded prototype. A publish returns only after the requested immutable record
appears in a sent-record acknowledgement. Fetch waits for a manual engine
fetch, then pages records from a durable local inbox. Delegate events are
serial. Fetched assets are copied before the delegate returns, and a following
state serialization is stored with the inbox state using an atomic replacement
and file-system flush. This preserves replay data before advancing the engine
change token.

Each durable inbox has a generation UUID included in its page cursor. If the
inbox is rebuilt, the coordinator rejects the old cursor and replays instead
of skipping records at an offset that now means something different.

Unit tests cover durable inbox replay, duplicate delivery, cursor validation,
and account binding without contacting iCloud. Earlier signed Mac and iPhone
round trips passed for the version 1 single-note app. A signed Mac notebook
launch has now joined the existing canonical note and synced a newly created
folder. Cross-device physical notebook delivery and physical iPad behavior
remain unverified. Other open checks include push-driven scheduling, offline
handoff, account changes, and server conflicts.

## Throttling

Foreground polling does not override Apple's retry deadlines. The adapter
persists the longest active retry-after delay, including per-record errors,
and waits before making further requests. A small availability-only file
also gates account discovery after app restart; it is never used as proof of
account identity. Pending snapshots remain durable throughout the cooldown.
If Apple reports throttling or service unavailability without a usable delay,
the adapter waits 30 seconds. A failed cooldown write stops further requests
until the adapter is recreated from durable state.

Tests cover nested retry metadata, fallback delays, deadline persistence,
pending uploads, and startup gating with a simulated clock. They do not
intentionally trigger Apple's real quota or throttling mechanisms. Adaptive
scheduling, upload batching, and push delivery are milestone 3 work.
