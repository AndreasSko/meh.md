# Code health review

Date: 2026-09-29. Reviewed state: `codex/sync-reliability` at `394826d`.
Branch for this review: `codex/code-review` (no code changes).

## The short version

The code base is in better shape than its size suggests. The durability
rules are clear, the code follows them in every path that was checked, and
most sync tests check real outcomes (replicas converge, deleted notes stay
deleted, a lost acknowledgement does no harm). All 819 unit tests pass
locally in about 45 seconds, and CI runs the full `swift test` suite.

There are three main problems:

1. **The cloud data model does not scale.** Every saved version of a note
   becomes a new CloudKit record holding the full history, and old records
   are never deleted. Storage, sync state and first-sync time grow with
   every edit session. This is the most important finding.
2. **The riskiest code has no tests.** No test ever runs the CKSyncEngine
   delegate: conflicts, failed saves, account changes and deleted zones.
   All convergence tests use an in-memory fake that behaves better than
   CloudKit.
3. **There is a lot of extra code.** About 7,000 lines are dead, spikes or
   duplicates, and there are 47 docs. On top of that, the transport and
   storage code contain several copies of the same safety checks. In the
   app, the sidebar, undo, settings and menus are custom-built instead of
   using what SwiftUI provides. That is the main reason the app feels
   "almost" native.

Code size today: 15k lines in `Sources/NoteCore`, 20k in `meh.md/`, 27k of
unit tests, 3.7k of UI tests, and 6.2k lines of docs.

## How this review was done

Six parallel read-only reviews covered: CloudKit transport, replica and
storage, test quality, editor, SwiftUI app layer, and build/docs. I then
checked the key claims myself against the code, the macOS 27 SDK headers,
[Apple's CKSyncEngine sample][sample], and the sync state on this Mac
(file sizes and record counts only, not note contents). Findings I
re-checked are marked *(checked)*. The others come from careful reading
with file references, but line numbers may be off by a few lines.

Not done: no iCloud runs, no device runs, no Instruments profiling, and no
visual check of the running app. The native-feel findings come from the
code, not from using the app.

[sample]: https://github.com/apple/sample-cloudkit-sync-engine

## Health by area

- **Sync core (replica, coordinator, storage): good, but too big.** The
  ordering is correct: apply, then persist, then move the cursor. Acks only
  cover the heads captured at upload time. Deleted notes cannot come back.
  Weak spots: heavy Automerge work on the main actor, a catalog lock that
  fails instead of waiting, and two copies of the storage code.
- **CloudKit transport: works, but it is the weakest part.** It is one
  2,676-line file with about 22 types. It has an unbounded record model, is
  not tested at the engine level, and has three copies of both its failure
  latch and its retry cooldown.
- **Tests: better than average in intent.** Most tests check behaviour.
  The gaps are the CKSyncEngine layer, randomized faults, and crash points.
  About 1,000 lines are duplicated fakes and helpers. Some tests use sleeps.
- **Editor: solid engineering.** TextKit 2 is used correctly and the custom
  parser is justified. But the macOS and iOS code is duplicated (about 400
  lines), and a remote change replaces the whole buffer and clears undo.
- **App layer: uses the right building blocks** (`NavigationSplitView`,
  `.searchable`, scene storage, `@Observable`). But the sidebar is
  hand-drawn and several system features are rebuilt by hand.
  `NotebookView.swift` is 2,246 lines with about 55 state properties.
- **Build and docs: fragile.** Each app file is compiled twice, in Swift 5
  (the app) and Swift 6 (the package). There is a spike package in the
  dependency graph and many historical docs.

## Recommendations, by priority

Priority follows your order: data safety, then responsiveness, then
simplicity. The last section suggests a PR order, which is not the same as
this list: some cheap cleanups make the big changes easier.

### P0-1 One CloudKit record per document, not one per version *(checked)*

**Problem.** The record name is the SHA-256 of the snapshot bytes
(`SyncTransport.swift:73-85`, `CloudKitSyncTransport.swift:815-817`). Each
sync of an edited note uploads its full Automerge history as a new record.
Records are only deleted when a note is permanently deleted (`purge…`,
`CloudKitSyncTransport.swift:1935-2010`). The local transport state also
keeps every snapshot, base64 in one JSON file (`inboxSlots`, `:40`, `:182`).
It rewrites and fsyncs that whole file on every engine state update
(`:450-452`, `:2393`).

Measured on this Mac (iCloud Dev container, about two weeks of use):

- Note files on disk: 0.68 MB for 314 notes.
- `Notebook/CloudKit/cloudkit-sync-state.json`: **13 MB**.
- 938 inbox slots, 461 live snapshots for only 255 documents. One note has
  83 stored versions, and the catalog has 74.

Each new version is the full history, so storage grows faster than the
notes do. The catalog grows too: switching the note you edit writes a new
catalog version (`recordRecentActivity`, `NotebookReplica.swift:392`).

**Why it matters.**
- A new device, or a reset, downloads every version ever uploaded, which
  explains some of the slow syncs.
- Every engine state update rewrites megabytes on the sync path.
- Cloud quota runs out eventually. `quotaExceeded` is not retried
  (`NotebookSyncRetryPolicy.swift:47-51`), so sync would stop.

**Fix (recommended, structural).** Use one record per document with a
fixed name (`note-<uuid>`, `catalog-<notebookID>`). The asset is the
document's latest `save()`. This is the standard CKSyncEngine pattern and
it suits a CRDT well:

- **Sending:** the record provider reads the current local file when the
  engine asks for it. The local file is the outbox; no snapshot copies are
  kept. Store the last known server record (system fields) per document so
  that saves carry change tags.
- **Conflict:** on `serverRecordChanged`, merge `error.serverRecord`'s
  asset into the local document and re-queue the save. Apple's sample does
  exactly this. A merge never loses data, so overwriting after a merge is
  safe. Keep the existing "incoming history must contain current heads"
  guard as a check.
- **Receiving:** merge the fetched asset into the local file, persist it,
  and only then persist the engine state. The merge is idempotent, so a
  crash just causes a harmless replay. No inbox is needed.
- **Permanent delete:** delete that one record. The catalog tombstone
  already prevents resurrection.
- **Bootstrap:** two fresh devices race to save `catalog-<id>`. The loser
  gets `serverRecordChanged` and adopts the server catalog. That may
  replace most of the canonical-proposal machinery. Verify this with a
  design spike before promising it.
- **Migration:** use a new zone (`…-v3`). Every device already has the full
  data locally, so each device uploads what it has and merges on conflict.
  Delete the old zone once all devices are updated. This is manageable
  while the app is on TestFlight.

What goes away: content-hash IDs, the inbox/outbox and its paging cursor,
the full-state JSON rewrites, most of the ack bookkeeping, and probably
half of `CloudKitSyncTransport.swift`. Write an ADR first, since this
reverses a deliberate earlier choice ("immutable full-history snapshots",
`architecture.md`).

**Smaller alternative, if the redesign has to wait.**
- Delete a record once an acknowledged record for the same document has
  heads that include its heads.
- Drop superseded inbox slots.
- Move snapshot bytes out of the JSON into files named by ID.
- Put `engineState` in its own small file.

This limits the growth but keeps most of the complexity.

### P0-2 Test the CKSyncEngine delegate *(checked)*

**Problem.** No test creates a `CloudKitSyncTransport` or calls
`handleEvent` or `nextRecordZoneChangeBatch`. `git grep CKSyncEngine
Tests` finds nothing. Untested paths include:
- `serverRecordChanged` (`:2472`)
- mixed saved/failed results
- `accountChange` (`:2529`)
- zone deletion (`:2540`)
- `unknownItem` and `zoneNotFound`

Every convergence test runs against `InMemorySyncTransport`, which only
models offline and lost acks. It is also a test-only fake that ships in
the production module.

**Fix.**
- Put the delegate logic behind a plain function, e.g. `apply(_ event:
  EngineEvent, to: inout TransportState) -> [Effect]`, where
  `EngineEvent` is our own enum. The thin CKSyncEngine adapter converts
  engine events into it, so tests never have to build CKSyncEngine types.
- Write table-driven tests with one row per event and error code. `CKRecord`
  and `CKError` (including `serverRecord` in userInfo) can be built in
  tests.
- Do this before P0-1, so the redesign has a safety net. P0-1 then makes
  this layer much smaller.

### P1-1 Randomized fault tests and crash-point tests

**Problem.** `NotebookSyncStressTests.testSeededThreeReplicaDisruption…` is
the best test in the suite, but its faults follow a fixed script. No test
kills the process between "CloudKit accepted" and "state persisted", or
between "record applied" and "cursor saved". Only `ENOSPC` is injected, and
only at the store level.

**Fix.**
- Build one fault-injecting fake transport in a new `NoteCoreTestSupport`
  target. Each seeded step picks a random action: edit, create, trash,
  delete, go offline, lose an ack, partially fail a batch, expire the
  cursor, redeliver, or restart a replica from disk.
- After everything settles, check the invariants:
  - all replicas are equal;
  - every acknowledged edit is present;
  - no deleted note is back;
  - a replica reopened from disk equals the live one.
- Add crash points as named hooks in the store. The stage injectors already
  exist; extend them.
- Run 3 seeds by default and more in CI (`MEH_NOTEBOOK_STRESS_SEEDS`
  already exists).

### P1-2 Fix the outgoing batch path *(checked)*

**Problem.** `nextRecordZoneChangeBatch` (`:2603`) writes an asset file and
takes a lease for **every** pending save before building the batch
(`prepareEngineBatchRecords`, `:2275-2307`). The SDK header says the batch
initializer "iterates over `pendingChanges` … until … the size of the
batch reaches the maximum limit" (`CKSyncEngineRecordZoneChangeBatch.h`),
and the limit is 250 records (`CKSyncEngine.h`). Records that don't fit
are never reported back, so their leases are never released
(`CloudKitAssetStaging.users`). The next call adds another lease for the
same records.

**Why it matters.**
- With more than 250 pending saves, which can happen after a long time
  offline, all pending bytes are rewritten on every batch.
- The staged files stay until the app relaunches.
- `purge` throws "A snapshot is still being staged for upload" for those
  IDs (`:990-995`), which blocks permanent deletion.

**Fix.** Stage inside the `recordProvider` closure, which is `async` in the
Swift API, and lease only what the provider returns. After P0-1 this
becomes "read the current file".

### P1-3 Handle engine errors the way Apple's sample does *(checked)*

**Problem.**
- On `serverRecordChanged`, `handleEvent` makes a network request
  (`database.record(for:)`, `:2473-2477`) through `cloudRequest`. That can
  sleep for the whole retry cooldown inside the engine callback
  (`waitForRetryWindow`, `:2151`).
- `zoneNotFound` and `unknownItem` fall into the generic failure branch
  (`:2517`) and are never re-queued. The data stays in the outbox, but
  uploads stall until the next launch.

**Fix.**
- Use `failure.error.serverRecord`. With content-hash IDs, a same-ID
  conflict is already an ack.
- For `zoneNotFound`, add `.saveZone` and re-queue the save. For
  `unknownItem`, re-queue.
- Never make network calls from `handleEvent`.

### P1-4 One queue for all catalog writes *(checked)*

**Problem.** `withCatalogWrite` throws `.busy` if another write is running
(`NotebookReplica.swift:1319`). Most operations use it directly: rename,
move, trash, import, permanent delete, and sync's `apply` for every
unopened note (`:991`). Only a few use the queued variant. So a sync pass
fails if you rename a note or run an import at the same time. And a rename
during a download fails with "The notebook is updating."

**Fix.** Make the queued, first-in-first-out version the only entry point
and remove `.busy`. The waiter-release code is copied three times
(`:153`, `:794`, `:1318`); keep one copy.

### P1-5 Move Automerge work off the main actor *(checked)*

**Problem.** `NotebookReplica` is `@MainActor`. For every downloaded note
that isn't open, `apply` does two full Automerge loads, a merge and a full
save on the main thread (`:991-1004`). `persistCatalog` serialises the
catalog twice and decodes it again. The README mentions "every now and then
a quick hiccup"; this is a likely cause during sync (not profiled).

**Fix.**
- Give `NoteFileStorage` (already an actor) a `merge(_ remote:) -> heads`
  method, and keep only the ordering guard on the main actor.
- In `persistCatalog`, take one snapshot and install from the document
  instead of re-decoding it.
- Check with Instruments before and after.

### P1-6 Build the app the way it is tested *(checked)*

**Problem.**
- The Xcode app compiles every file in `meh.md/` itself through a
  synchronized folder, and links only `NoteCore`. The `NativeEditor` and
  `NotebookAppModel` package targets exist only so tests can compile a
  second copy of the same files.
- The app builds in `SWIFT_VERSION = 5.0` (`project.pbxproj:468`); the
  package builds in Swift 6. So the tests check a Swift 6 build of files
  that ship as Swift 5, with weaker concurrency checks.
- The include/exclude lists in `Package.swift` have already drifted. The
  build warns about 2 unhandled files per target:
  `NoteHistoryBrowserView.swift` and `NotebookRecentUIKitList.swift`.

**Fix.**
- Move the files into `Sources/NativeEditor` and
  `Sources/NotebookAppModel`, and have the app link all three products.
  This removes about 80 of the 140 lines in `Package.swift`.
- Set the app and UI test targets to Swift 6.
- Cost: types the app uses must become `public`.
- If that is too much for now, at least switch the app to Swift 6 mode.

### P2-1 Delete the dead single-note code *(checked)*

These have no path from the running app (`MyApp` → `NotebookWorkspace` →
`NotebookApplicationView`):

- `meh.md/AppWorkspace.swift` and `ContentView.swift` (562 lines). This
  includes an old 3-second polling sync loop, which can mislead future
  changes, including AI-driven ones.
- `MarkdownCopyController/Writer/Types.swift` (1,350 lines), plus 788 lines
  of tests.
- `NoteSyncCoordinator`, `NotebookLegacyBridge` and `NotebookMigration`
  (696 lines), plus about 1,100 lines of tests. First move
  `NoteSyncCoordinator.Status` into `NotebookSyncCoordinator`.
- The legacy paths inside live files, about 250 lines:
  - `legacyNote:` parameters and `ProposalWithoutLegacy` in the coordinator
  - legacy migration receipts in `NotebookCatalog`
  - `mode == .legacy` in the codec
  - `adoptLegacy` in the replica

  Swift's synthesized `Decodable` ignores unknown keys, so old state files
  still load after these are removed.
- `Spikes/AutomergeSpike` (1,275 lines). It is a root dependency only
  because `NativeEditorIntegrationTests` uses `SpikeNoteDocument` as a text
  box. As a result, those tests check a binding path the app doesn't use.
  Switch them to `NoteSession` (the real commit path), or to a plain string.
- `Tools/Editor*` and their scripts (about 850 Swift and 350 shell lines),
  which CI never runs. Move any useful checks into `NativeEditorTests`.
  Keep `Tools/CloudKit` and `Tools/LocalSyncServer`.

That is about 7,000 lines with no change in behaviour. Doing it first makes
every other change cheaper.

### P2-2 Split the transport and remove its duplicate checks

This mostly still applies after P0-1, and is smaller then.

- **One failure latch.** Failure is latched in three places: the store's
  `writeHealth`, `CloudKitEventCommitter.failure`, and the transport's
  `delegateFailure`. The "unexpected deletion" flag has one copy in memory
  and one on disk, so every guard re-checks after an `await`
  (`canOfferOutgoingBatch`, `haltStatus`, `assertHealthy`). Fix: have
  `commitFetched` return the deletion flag, and add one synchronous
  `haltError()`. `CloudKitOutgoingBatchPreparer` then shrinks to a few
  lines.
- **One retry cooldown.** The cooldown is stored in `retryThrottle`, in
  `availabilityCooldown`, and in `state.retryNotBefore`, with code to
  reconcile them. Keep only the cooldown file.
- **Validate once.** Each record is validated about 5–6 times per upload,
  each time with a full Automerge load and a SHA-256. Validate once at each
  trust boundary and pass a validated wrapper type along.
- **Fewer account checks.** Two account round trips run on every
  bootstrap, publish, fetch and purge. Check once at startup and rely on
  `.accountChange`.
- **Drop the bootstrap validation cache.** It is an LRU with byte budgets
  for about two records, and two test files test only the cache itself.
  Remove it.
- **Small duplicates.** The lease-release loop is copied three times, and
  there are pass-through wrappers and single-use types.
- **File split.** State model, state store, record codec, asset staging,
  retry cooldown, batch result resolver, lab (DEBUG), public actor, and the
  engine delegate as `+Engine.swift`.

Estimate: 400–600 fewer lines.

### P2-3 One durable file store, and a real disk flush

- `NoteFileStorage` and `NotebookCatalogStorage` are near copies: the same
  load, recover and write code, plus 8 pairs of matching types.
  `SyncFileIO.replace` is a third atomic-write implementation. Merge them
  into one `DurableDocumentStore<D>`. That saves about 300 lines, and each
  durability fix then lands once.
- Each note save does three full Automerge loads and copies the previous
  file's bytes. Keep the decoded document around, and use a hard link plus
  rename for the previous file.
- `fsync` on Darwin doesn't flush the drive cache (`man 2 fsync`, *(checked)*).
  Use `fcntl(F_FULLFSYNC)`, falling back to `fsync`, in the single IO
  helper. Measure it on a device and update the durability contract.

### P2-4 Stop re-reading every note on each sync pass

`replica.records()` reads every `note.automerge` file. It runs in
`containsHistory`, once per download page, for outgoing, and at the end of
`exchange`. Several caches exist only to soften this: `recordReadCache`,
`NotebookHistoryChecker`'s LRU, and `ValidatedProposalCache`.

Keep an in-memory `[DocumentKey: heads]` index, updated by the replica's own
writes. P0-1 removes most of this path anyway.

### P2-5 Test cleanup

- **Shared test support.** Move `InMemorySyncTransport` out of `NoteCore`
  into `NoteCoreTestSupport`, and replace the 16+ hand-written transport
  fakes with one scriptable fake (9 of them are in
  `NotebookSyncCoordinatorTests` alone). Put the 25 temp-directory helpers
  and 4 `waitUntil` copies there too. Saves about 800 lines.
- **Use a test clock, not sleeps.** `NotebookWorkspaceSchedulingTests` uses
  250 ms and 1 s sleeps to prove that nothing happened.
  `testBackgroundFlushesOnceAndForegroundResumes` alone takes 10 s. Inject
  a clock, the way `NoteSession` already does (`sleep:` parameter). UI
  tests use `Thread.sleep(1)`; wait on a condition instead.
- **Tests that mirror the implementation.** Rewrite these to assert the
  real rule:
  - `testUploadsNotesInChunksBeforeCatalog` asserts `[50, 1, 1]`. The real
    rule is "no catalog is sent before its notes are acknowledged".
  - Several tests decode `notebook-sync-state.json` directly. Instead,
    reopen the coordinator and check what is re-sent.
  - `testOutgoingBatchStopsBeforeReadingForEveryHaltCause` loops over
    reason strings that change nothing.
  - Editor tests assert `parseCount` / `incrementalParseCount`. Keep one
    performance guard and the tests that compare incremental and full
    parses.
- **Missing tests.** `NotebookBrowserUndo` has no tests, and it is
  user-facing data behaviour.
- **Framework.** Everything is XCTest, which is consistent. Swift Testing's
  `@Test(arguments:)` would fit new table-driven tests (P0-2).

### P2-6 Editor: share the platform code, and apply small remote changes

- `MarkdownEditor.swift` has two near-copies of the representable and
  coordinator. About 405 of 650 lines are the same, and they include the
  revision, commit and stale-parent logic. Move that into one
  `MarkdownEditorSession`, with a small host protocol per platform. This
  saves about 400 lines, and a sync fix then lands on both platforms.
- A remote change replaces the whole buffer, causes a full re-parse and
  re-layout, and clears undo: `removeAllActions()`, `:1178` and `:2329`,
  *(checked)*. With two devices editing, Cmd-Z silently disappears.
  Replace only the changed middle range (common prefix and suffix). Then
  undo can usually be kept, and the incremental parse path applies.
- The undo observer listens to every `UndoManager` in the app
  (`object: nil`). Scope it to the text view's undo manager.

### P2-7 Native feel

This is the main source of "not quite native". It is ordered by how much a
user would notice.

1. **Use a real sidebar.**
   - Today: `.listStyle(.plain)` with a custom background
     (`NotebookView.swift:1728`), custom section toggles and chevrons, a
     hand-flattened tree with manual indents, and Recents drawn as cards.
   - Use `.listStyle(.sidebar)`, `Section(isExpanded:)` for Recents and
     Files, and `DisclosureGroup` or `OutlineGroup` for folders.
   - You get the system look and selection, arrow-key expand and collapse
     on Mac, VoiceOver outline semantics, and Dynamic Type spacing.
   - About 200 lines go.
2. **Put commands in the menu bar.**
   - ⌘N currently opens a new window, because nothing replaces `.newItem`
     *(checked)*.
   - New Note, New Folder, Move, Move to Trash and Rename exist only as
     `onKeyPress` handlers while the browser has focus. They don't show up
     in the menu bar or the iPad shortcut overlay.
   - Add a `Commands` type that reads a focused action object.
3. **Use the system undo for moves and trash.**
   - Today there is a custom `browserUndo`/`browserRedo` stack with
     "Undo Move" buttons.
   - Register with `@Environment(\.undoManager)` instead. Then ⌘Z, shake
     to undo and three-finger undo all work, which also protects against
     trashing something by accident.
4. **Settings and Trash.**
   - Add a `Settings` scene on Mac (⌘,).
   - Make Trash a sidebar item, like "Recently Deleted" in Notes, instead
     of a sheet opened from floating glass buttons at the bottom of the
     sidebar.
5. **Let selection drive navigation.**
   - Opening a note on a Mac click uses a `simultaneousGesture` that reads
     `NSEvent.modifierFlags`. Use `List(selection:)` with `onChange`
     instead.
   - Select-all in rename uses `sendAction` after a `Task.yield`, plus an
     app-wide `UITextField` notification. Use `TextField(text:selection:)`.
6. **Drag and drop** notes onto folders (deferred in #49). This becomes
   easy once the tree is native.
7. **Recents UIKit bridge.** `NotebookRecentUIKitList.swift` puts a
   `UITableView` inside one list row, with height workarounds and a second
   copy of the menu. It works around a swipe/reorder glitch (e88dad2).
   Check whether iOS 27 still shows the glitch; if not, remove the bridge.
8. **Keyboard formatting bar.** It is a custom `UICollectionView` with
   drag-to-reorder and hand-made glass capsules (about 430 lines,
   `EditorWritingControls.swift`). System keyboard bars don't reorder.
   Consider a standard accessory bar that scrolls. This is your design
   call, since bc7a8ca was deliberate.
9. **Let the system set sizes.** Drop the fixed paddings, heights and
   corner radii (12/14/16, 28/36/44, 10/16) in the sidebar code.
10. **Stop the idle redraw.** The sync button redraws every second through
    `TimelineView(.periodic…)`, even when idle. Use the timeline only while
    a retry countdown is shown.

Structure: `NotebookView` (2,246 lines, about 55 `@State` properties)
should be split into sidebar, detail and a shared actions object. Each row
looks up its placement with `placements.first(where:)`, so rendering is
O(n²) for large notebooks; build a dictionary once.
`NotebookWorkspace` (954 lines) should hand backups to its own controller.

### P3-1 History on large notes

This is likely, though not profiled:
- Each step of the slider synchronously rebuilds the text at old heads on
  the main actor.
- Each step replaces the whole buffer.
- On iOS, restoring the position calls `ensureLayout` for the whole
  document (`MarkdownEditor.swift:2177`, *(checked)*).
- Building the list of versions runs one Automerge diff per change.

Fixes: load text when the drag ends, compute it off the main actor, and
lay out only up to the anchor.

### P3-2 Docs: 47 files down to about 20

- **Keep:** the contracts, ADRs and setup guides (product, architecture,
  durability, core, sync, import, deletion, search, navigation, backups,
  development builds, TestFlight, `decisions/`).
- **Merge:**
  - the sync progress, scheduling, validation and local-service docs into
    the sync contract;
  - the two recovery docs into one;
  - the 8 performance docs (about 1,600 lines) into one
    `performance.md` with current budgets and how to re-measure.
- **Archive or delete:** the milestone and wave plans, `plan.md`, spike,
  investigation and dated verification records (about 2,500 lines). Git
  keeps them. Also drop the "Earlier single-note copy" section of
  `markdown-copy-contract.md`.

This cuts about 3,300 lines, and readers (and AI agents) stop being led
toward outdated designs.

### P3-3 Small hygiene items

- No formatter or linter is set up. Add `swift format lint` to CI; it ships
  with the toolchain.
- Fix the live warning at `MarkdownEditor.swift:660`, and treat warnings as
  errors in CI.
- `notebook-sync.yml` uses tag-pinned actions, while `testflight.yml` pins
  SHAs. Pin both by SHA.
- Replace magic numbers (50, 1,000, 16/32 MiB, 200, 250) with named
  constants.
- `CloudKitSyncTransportError.snapshotTooLarge` is special-cased inside the
  generic coordinator. Move it into `SyncError`.
- Replace `AnyView` in `NotebookNoteEditor` with a generic title view.

## Suggested PR order

1. 🔥 Remove the single-note code, the spike and the editor tools (P2-1).
   No behaviour change, and it shrinks everything below.
2. Real package modules and Swift 6 for the app (P1-6).
3. Test support target, shared fake, test clock (P2-5), then the delegate
   test harness (P0-2).
4. Transport fixes that don't change the data model: lazy staging, error
   handling, one latch (P1-2, P1-3, part of P2-2).
5. One catalog write queue, and Automerge off the main actor (P1-4, P1-5).
6. ADR and design spike for one record per document, then the migration
   (P0-1). The randomized fault test (P1-1) should exist before this ships.
7. One durable store and `F_FULLFSYNC` (P2-3). Parts may fall out of step 6.
8. Native-feel PRs (P2-7), which are independent of the sync work and can
   run in parallel from step 2 on. Start with the sidebar and the menu
   commands.
9. Docs cleanup (P3-2), best done after steps 1 and 6.
