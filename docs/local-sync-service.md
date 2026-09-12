# Local sync service

Milestone 2 includes a small localhost service for testing the complete sync
path without an account or CloudKit container. It stores immutable,
full-history
Automerge snapshots. It is a development tool and does not provide
authentication, encryption, discovery, or internet-facing deployment.

## Start the service

Choose a private data directory outside the repository and run:

```sh
python3 Tools/LocalSyncServer/local_sync_server.py \
  --data-dir /tmp/meh-local-sync --port 8765
```

The process always listens on `127.0.0.1`. The data directory is required so
the caller makes persistence explicit. Stop the process with Control-C. A later
process using the same directory retains workspace history and keeps issued
cursors valid. Each client persists its own cursor position.

Configure a debug app process with a loopback base URL and a stable workspace
name. `LocalSyncTransport` combines both values in its public `scope`, so the
coordinator can detect a server or workspace change.

```text
MEH_SYNC_URL=http://127.0.0.1:8765
MEH_SYNC_WORKSPACE=personal-development
```

## Storage behavior

Each workspace is an independent append-ordered record collection. Its file
name is the SHA-256 digest of the workspace string; a workspace cannot select a
filesystem path. Records are keyed by the SHA-256 digest of their decoded
snapshot data. Repeating an identical publish is a successful no-op. Reusing
an identifier with different snapshot metadata is rejected.

Bootstrap validates the proposed record and atomically chooses the first seed.
Every caller receives that canonical seed, and the seed is also the first
record returned by a replay. Concurrent requests are serialized around the
read, decision, and durable write.

Every mutation writes a complete temporary state file, calls `fsync`, renames
the file atomically, and calls `fsync` on the containing directory. The record
array is never reordered or deleted. Pages therefore have deterministic append
order. Cursors contain a version, workspace digest, and offset. A malformed,
cross-workspace, or out-of-range cursor returns `invalid_cursor`; the client
must start a full replay with no cursor.

The process holds an advisory lock in the data directory for its lifetime. A
second service cannot open the same directory and risk overwriting updates from
the first process.

Requests are limited to 16 MiB. Responses are checked by the Swift adapter and
the service limits each page to 24 MiB before sending it. The cursor advances
only past records included in that bounded page. Client requests time out after
five seconds by default and the timeout is clamped between 250 milliseconds and
30 seconds.

## HTTP API

The service accepts JSON at these endpoints:

- `POST /v1/bootstrap` with `scope` and `record` returns the canonical seed.
- `POST /v1/records` with `scope` and `record` durably publishes the record.
- `GET /v1/records?scope=...&after=...&limit=...` returns a `SyncPage`.

The record and page shapes use Swift's synthesized `Codable` representation.
Snapshot `data` is Base64, `noteID` is a UUID string, and `heads` is an array.
No endpoint accepts a filesystem path or credentials.

## Verification

Run the persistent service tests without third-party packages:

```sh
python3 -m unittest discover -s Tools/LocalSyncServer -p 'test_*.py'
```

Run the Swift transport and coordinator tests with:

```sh
swift test --disable-sandbox \
  --filter 'SyncTransportTests|NoteSyncCoordinatorTests'
```

## Two running simulator apps

Start the service on port 8765 as above. Build the UI-test bundle:

```sh
xcodebuild -project meh.md.xcodeproj -scheme meh.md \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/meh-sync-build \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

Choose an iPhone and iPad simulator UDID from `xcrun simctl list devices`.
The runner uses a unique test workspace and preserves each ordinary note:

```sh
python3 Tools/LocalSyncServer/run_simulator_checks.py \
  --products-dir /tmp/meh-sync-build/Build/Products \
  --phone <iphone-simulator-udid> --pad <ipad-simulator-udid>
```

It drives actual native typing through XCTest, checks iPhone-to-iPad-to-iPhone
delivery and relaunch, and independently compares both Markdown files. It
prints the evidence directory containing logs, result bundles, and a JSON
verification report. It does not start/stop the service or erase simulators.

The Debug app normally polls while active. Set `MEH_SYNC_AUTOMATIC=0` to use
only Sync Now during deterministic UI checks. The runner sets this itself.
Test copies appear under `Files / meh.md / SyncWorkspaces / <workspace>`;
internal state is isolated by the endpoint/workspace scope hash.
