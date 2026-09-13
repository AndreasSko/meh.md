# CloudKit synchronization setup

The CloudKit adapter targets the private database in
`iCloud.de.andreas-sk.meh-md`. It uses one custom record zone, immutable
full-history Automerge snapshots, and `CKAsset` document payloads. It does not
delete or compact remote history in milestone 2.

The app target still needs these Xcode capabilities before real-device sync
can run:

- iCloud with CloudKit enabled and the container
  `iCloud.de.andreas-sk.meh-md` selected.

Those settings require an active Apple Developer Program membership, a
container registered for team `9YFM7J3EH3`, and regenerated signing profiles.
The current repository does not prove that the container exists or that the
team can sign for it. The container and production schema must not be created
or deployed as a side effect of unit tests.

Enable Background Modes with Remote notifications when adding push-driven or
background synchronization. Manual foreground exchanges do not require it.

Create the transport only after selecting an Application Support directory:

```swift
let transport = try await CloudKitSyncTransport.make(
    containerIdentifier: "iCloud.de.andreas-sk.meh-md",
    stateDirectory: syncStateDirectory
)
```

The app's Debug launch opt-in is `MEH_SYNC_CLOUDKIT=1`. Leave
`MEH_SYNC_URL` unset when using it. Existing local notes open before account
discovery completes; setup failures leave editing available and show a retry
action. The default app remains local-only until this explicit opt-in.

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
and account binding without contacting iCloud. Signed Mac, iPhone, and iPad
runs are still required to verify provisioning, push-driven scheduling,
offline handoff, account changes, server conflicts, and observed latency.
