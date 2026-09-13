# Milestone 3: a usable notebook

Started: 2026-09-13. First branch: `codex/milestone-3-notebook-core`.

## Closeout: 2026-09-13

Implementation is complete. The consolidated stack was reviewed by
CodeRabbit, all actionable findings were confirmed fixed, and all three PRs
were merged into main:

- [#14: notebook foundation][pr-14]
- [#16: sync progress and diagnostics][pr-16]
- [#18: permanent deletion and automatic sync][pr-18]

Final local validation passed 317 Swift tests (286 core, 26 native editor,
and 5 app-model tests) and 16 Python tests. Signed Mac iCloud Dev build and
iOS Simulator build-for-testing passed. The [final CI run][final-ci] passed.
The earlier stage counts below are historical evidence.

Device-level sync acceptance remains incomplete. The updated iPhone can
remain paused by saved unexpected-deletion state; [recovery][recovery-issue]
is the first Milestone 4 priority. [Automatic receiving on Mac][mac-issue]
also remains unverified. Preserve local notes and unsynced edits; no cloud
reset is authorized or required by this closeout.

GitHub issues track [export and restore][export-issue],
[replication performance][performance-issue], and
[Markdown fidelity fuzzing][fuzz-issue]. Daily-use findings will be tracked
there rather than extending this historical execution record.

[pr-14]: https://github.com/AndreasSko/meh.md/pull/14
[pr-16]: https://github.com/AndreasSko/meh.md/pull/16
[pr-18]: https://github.com/AndreasSko/meh.md/pull/18
[final-ci]: https://github.com/AndreasSko/meh.md/actions/runs/34768214371
[recovery-issue]: https://github.com/AndreasSko/meh.md/issues/22
[mac-issue]: https://github.com/AndreasSko/meh.md/issues/24
[export-issue]: https://github.com/AndreasSko/meh.md/issues/20
[performance-issue]: https://github.com/AndreasSko/meh.md/issues/21
[fuzz-issue]: https://github.com/AndreasSko/meh.md/issues/23

## Outcome

Deliver multiple notes, nested folders, safe Markdown import, recoverable
trash, structured Markdown copies, and library-wide CloudKit synchronization.
Keep the existing native editor and local-save guarantees.

## Reviewable stages

1. Notebook core: catalog, conflict rules, local storage, and single-note
   migration. Exercise concurrent operations before building the interface.
2. Notebook replication: multiple document identities, durable progress,
   metadata/content arrival ordering, permanent-deletion markers, and a
   versioned cloud transition.
3. Native navigation: folders, notes, switching, rename, move, and Trash.
4. Library import, managed Markdown hierarchy, and permanent-deletion cleanup
   with interruption recovery.
5. CloudKit scheduling/batching, scale measurements, and device acceptance.

Use focused commits and stack later PRs when their dependencies justify it.
The coordinator owns architecture, integration, and final verification.
Smaller-model agents handle bounded helpers, fixtures, and independent review.

## Feedback checkpoints

Pause after the core stage with concrete conflict examples and test results.
Ask for behavior feedback before wiring those rules into the notebook UI.
Show the first working navigation before expanding import and copy controls.
Continue fixes within a stage without repeatedly asking for permission.

## Proposed core contract

- Each note retains its own Automerge document and stable UUID.
- A separate Automerge catalog owns stable folder/note IDs, names, parent
  relationships, and trash state. It contains no note bodies.
- Rename and move update independent properties. Concurrent conflicts converge
  deterministically; losing values remain in Automerge history.
- A concurrent trash/restore conflict favors trash until an explicit restore
  observes and resolves it. Editing a trashed note never deletes its content.
- Trashing a folder hides its descendants through ancestry, without rewriting
  each descendant. Restoring the folder exposes those descendants again.
- Duplicate sibling names are retained, never merged or overwritten. Resolve
  display/export names deterministically from stable IDs.
- Reject locally requested cycles. Resolve cycles or missing parents received
  through merging into a deterministic, visible recovery placement.
- Persist note content before catalog references. Missing referenced content
  is unavailable, never silently replaced by a new empty document.
- Migrate the old note by copying its exact Automerge state into ID-based
  storage before adding its catalog entry. Retain the legacy files. Repeating
  an interrupted migration must preserve identity and avoid duplicates.
- This first stage does not activate notebook storage in the running app or
  change the existing CloudKit zone. Cloud transition and app wiring follow
  after core review; old app builds must not consume catalog records.

## Validation

Test concurrent rename/move, collisions, cycles, folder trash, restore versus
trash, and merge-order convergence. Test migration retries and file-write
interruptions. Reuse existing local-save and native-editor regressions.

Later stages add multi-replica transport tests, exact import/copy comparisons,
Mac and iOS builds, simulator app checks, then live CloudKit/device checks.
Record measured scale and energy evidence separately from inferred benefits.

## Existing workspace changes

The checkout started with Xcode project and plist changes plus a generated
Swift package scheme. The owner authorizes including relevant changes.
Inspect and validate them before including them in a commit. Preserve source
copies of the initial diffs while separating meaningful settings from churn.

## Stage 1 checkpoint: 2026-09-13

The core, catalog file store, and resumable legacy migration are implemented.
The [core contract](notebook-core-contract.md) records the behavior for review.
No app migration or notebook cloud upload has been activated.

- Validation: 155 Swift tests passed (133 core and 22 native editor), including
  51 new notebook tests. Mac and generic iOS Simulator Local builds passed.
- Catalog tests cover independent offline metadata edits, two/three-replica
  folder cycles, collision allocation, and Trash hierarchy/concurrency.
- Storage tests inject errors at save/recovery boundaries. Migration tests
  cover exact source bytes, retries, source disappearance/replacement,
  disconnected histories, and explicit destination recovery.
- Independent smaller-model review found and helped resolve migration source
  identity gaps, filename-length overflow, and ambiguous Trash placement.
- Xcode/plist normalization retains Files access and documents-in-place
  support. The generated iOS Local plist confirms those flags and keeps
  multiple scenes disabled. Preserve the prior entitlement-file exclusion.
- The generated Swift-package Xcode scheme is ignored, not deleted.
- No new process-kill, physical-device, live CloudKit, scale, or energy claims
  are made for this stage. Those follow the integration stages.

The owner accepted the Trash behavior and permanent-deletion plan. Implement
Delete Permanently and Empty Trash only after durable deletion markers and
actual content cleanup are ready. See the core contract for exact semantics.

## Stage 2 checkpoint: 2026-09-13

Notebook replication is implemented without changing the running app.
The [sync contract](notebook-sync-contract.md) describes its guarantees.

- Validation: 190 Swift tests passed (168 core and 22 native editor), plus
  13 Python service tests. Mac and generic iOS Simulator Local builds passed.
- A real loopback HTTP test joins two fresh replicas, exchanges concurrent
  Unicode edits, reopens both replicas, and checks exact convergence.
- Injected tests cover interrupted bootstrap, partial arrival, save failure,
  rollback replay, scope isolation, pending edits, and permanent markers.
- CloudKit record codecs and durable mode isolation are tested locally.
  Live notebook CloudKit delivery and signed-device behavior remain untested.
- Permanent markers suppress resurrection, but content cleanup and its UI
  remain deferred. Current exchanges are finite and explicitly invoked;
  background scheduling, batching, scale, and energy measurements follow.

Next: review navigation behavior before wiring the notebook into the app.

## Stage 3 early UI checkpoint: 2026-09-13

At this checkpoint, the
[navigation preview](notebook-navigation-preview.md) used an opt-in Debug
workspace. It supported local editing, folders, move, and Trash without
replacing the app's sync or Markdown-copy workflow. Its layout review preceded
the activation recorded below.

## Activation checkpoint: 2026-09-13

The notebook UI is now the default for both `meh.md Local` and
`meh.md iCloud Dev`. `MEH_NOTEBOOK_PREVIEW=1` remains available as a separate
preview workspace; it is not the activated notebook store.

- The one-way bridge under `Notebook/LegacyBridge` imports the retained
  version 1 note and later edits from older clients. It never writes notebook
  changes back to the source `Notes` directory.
- A fresh iCloud installation must be online to join the canonical version 1
  note before activating its notebook. Once activation has established the
  notebook locally, it opens for editing while offline.
- Active notes are published as structured Markdown copies under
  `Documents/Notebook Copies/Markdown`. Trashed notes are omitted. Earlier
  single-note copies remain in place but are no longer maintained.
- Managed copies remain one-way product output. External file edits are not
  imported into the notebook.
- The bounded prototype still polls while foregrounded. CloudKit scheduling,
  batching, and background change delivery remain stage 5 work.
- The full suite passes 219 tests: 193 core and 26 native editor tests. A real
  HTTP test covers version 1 upgrade, folder sync, and later old-client edits.
- Local and iCloud Dev builds pass for Mac and iOS. A signed Mac iCloud Dev
  launch joined the existing canonical note and synced a newly created folder.
  Cross-device physical iCloud and physical iPad acceptance remain unverified.
- No new visual activation claim is based on the blocked simulator inspection.
  The earlier preview checks remain the available interaction evidence.

## Owner activation feedback: 2026-09-13

The owner confirmed the iPhone iCloud Dev test works. This completes the
basic Mac/iPhone notebook activation checkpoint. It does not replace broader
offline/concurrent-operation acceptance or physical iPad checks.

The next stage is [Markdown library import](notebook-import-contract.md).
Permanent content cleanup and efficient CloudKit scheduling remain separate
follow-ups after the import flow receives feedback.

## Markdown import checkpoint: 2026-09-13

Markdown files and folder trees can now be copied into the notebook from the
native picker. A review shows counts and skipped paths before confirmation.
Sources remain unchanged; empty folders, names, Unicode, BOMs, line endings,
and unsupported Markdown syntax are retained. Matching names stay separate.

The notebook stores a resumable import job before writing note bodies and
commits the complete tree to the catalog only after those bodies are durable.
Resume uses the saved copy, preserves later edits and moves, and refuses
corrupt or conflicting state instead of overwriting it. Set Aside keeps the
saved job for recovery and permits a fresh import without deleting staged
bodies or already imported notes.

- All 238 Swift tests pass: 212 core and 26 native editor tests, with no skips.
  The real HTTP suite verifies import, cross-replica synchronization, exact
  nested Markdown output, and unchanged source files.
- Tests cover interruption around journal/body/catalog writes, resume after
  later edits, UUID/history conflicts, copied journals, missing bodies, and
  invalid trees. Scanner checks include hidden items, links, packages,
  overlapping selection, invalid UTF-8, and preserved empty folders.
- The 200-note/10-folder fixture plus one same-name note took 0.596 seconds
  for scan, import, and Markdown publication on this Mac. Batch catalog
  insertion removed repeated per-note placement calculation. This is a local
  fixture measurement, not a CloudKit latency or battery measurement.
- Mac Local and signed iCloud Dev builds pass. The iPhone iCloud Dev app and
  UI-test targets compile.
- The Mac preview picker, count/skipped-item review, completed folder tree,
  and opening an imported Unicode note were inspected. The selected source
  fixture remained unchanged after the UI import.
- Device Hub inspection timed out, so native iPhone import interaction and
  document-provider behavior still need owner feedback. Basic iCloud folder
  synchronization was already confirmed by the owner at the prior checkpoint.

Next: feedback on import, then permanent deletion and content cleanup. Cloud
scheduling/batching and broader device/scale acceptance follow separately.


## Sync visibility checkpoint: 2026-09-13

The owner confirmed that importing the full note library worked, then reported
that sync appeared to continue indefinitely. This checkpoint brings forward
upload batching and visible progress before permanent deletion work.

The former Markdown-copy location footer is replaced by active sync status.
It disappears at idle; the toolbar retains Sync Details and Sync Now. Note
counts reflect acknowledged saved revisions, with separate receiving and
folder metadata phases. Partial failures retain completed work and expose
errors or known retry deadlines. See the
[progress contract](notebook-sync-progress.md) for counting and retry
semantics.

CloudKit uploads notes in batches of up to 50 and drains buffered download
pages before a fresh fetch at the tip. Foreground activation and saved edits
request sync immediately; quiet checks now run every 30 seconds. This does
not yet implement full background change delivery.

The Mac UI was checked with 120 synthetic notes through a delayed loopback
service: upload progress appeared, switched to folder metadata, and vanished
when complete. This does not establish timing for the owner's iCloud library.

All 257 Swift tests pass: 231 core and 26 native editor tests, with no skips.
The suite includes real loopback HTTP replica checks. The signed Mac iCloud
Dev build and iPhone iCloud Dev app/UI-test compilation also pass.

Next: owner feedback on sync visibility with the imported library, then
permanent deletion and content cleanup. Full background scheduling and broader
device/scale acceptance remain outstanding.


## Sync diagnostics checkpoint: 2026-09-13

The owner reported an iPhone upload after receiving the library, followed by
a smaller upload count. Added bounded local event history to distinguish
missing acknowledgements, changed revisions, and partial-batch retries.
Sync Details exposes viewing, copying, sharing, and clearing the latest 500
events. Error summaries omit user content and identifiers. Logging is local
and best effort, with no change to sync decisions or document formats.

A diagnostic reproduction confirmed that an older build's advanced download
cursor with missing upload acknowledgements can cause unnecessary uploads
after upgrading. This is a possible explanation, not a confirmed diagnosis
of the owner's device. The 124-to-74 count is consistent with one completed
batch of 50 before retry. No upgrade reconciliation is included here; logs
from the affected device are the next evidence needed.

The Mac log UI showed a fresh 120-note loopback download with no outgoing
notes, followed by an unchanged manual sync. Full device-specific CloudKit
behavior remains an owner feedback checkpoint.

All 261 Swift tests pass, including log persistence, error redaction,
partial-retry diagnostics, and real HTTP replica tests. Signed Mac iCloud
Dev and iPhone app/UI-test builds pass.

## Permanent deletion checkpoint: 2026-09-13

Delete Permanently and Empty Trash now capture exact Trash identities before
confirmation. Durable local and replicated markers precede cleanup. Retryable
cleanup removes note/recovery files, retained import bodies, managed Markdown
copies, transport caches, and cloud note snapshots. Catalog markers remain.
An unseen offline child of a deleted folder survives at the recovery root.
See the [deletion contract](notebook-permanent-deletion.md).

The owner explicitly permits a development compatibility cut. The running
app no longer migrates or synchronizes the earlier single-note system.
Existing version 2 notebooks and imported notes stay intact, and open before
cloud discovery. Ordinary sync discards unused legacy proposal bodies without
requiring them to decode. Historical migration helpers remain covered as
isolated core utilities; they are no longer activation dependencies.

A Mac fixture verified Empty Trash confirmation, cancellation, successful
removal, cleared editor selection, and subsequent manual sync. The fixture
used an isolated loopback workspace, not the owner's iCloud notes.

The owner also raised recovery from broken cloud storage. The
[cloud recovery proposal](notebook-cloud-recovery.md) separates local access
and retry from a deliberate rebuild with a new cloud generation. No reset
button or cloud reset is included in this checkpoint.

All 284 Swift tests pass: 258 core and 26 native editor tests, including real
loopback HTTP exchanges. The local service passes 16 Python tests. Mac Local
and signed iCloud Dev builds pass, as does iPhone app/UI-test compilation.
Physical-device deletion acceptance remains an owner feedback check.

Next: owner feedback with disposable notes across Mac/iPhone. Full background
scheduling, broader offline/device acceptance, and cloud recovery remain
separate follow-ups.

## Automatic sync and CI checkpoint: 2026-09-13

The owner confirmed permanent deletion works on their devices. Their actual
library performance review is deferred to everyday use, with Markdown and
other quality-of-life improvements reserved for later work. Cloud reset
remains explicitly out of scope.

Cloud builds now enable CKSyncEngine scheduling and change notifications,
with durable activity delivery into the notebook coordinator. Saved changes
are coalesced, foreground activation reconciles pending work, and transient
app failures back off without bypassing server cooldowns. The iCloud Dev
configuration includes APNs entitlements and iOS background notification
mode. The cloud foreground polling timer is removed. See the
[scheduling contract](notebook-sync-scheduling.md).

The [local and CI runner](notebook-sync-validation.md) exercises the complete
Swift and Python suites without iCloud. Seeded three-replica scenarios cover
offline edits, restart, reordered/duplicate delivery, lost acknowledgements,
and permanent deletion. Synthetic imports verify durable reopen, initial
replication, and incremental edits at 100 notes on PRs and 100/500/1,000 on
the larger scheduled run. Hosted runs retain diagnostic logs as artifacts.

The remaining owner checkpoint is actual silent-notification delivery with
iCloud Dev on physical devices, including an offline edit followed by a
foreground handoff. System-controlled background latency is not guaranteed
by the deterministic suite. Real-library profiling and cloud reset do not
block this checkpoint.

GitHub Actions run [34759050114][scheduling-ci] passes all 301 Swift tests:
270 core, 26 native editor, and 5 app-model tests. All 16 Python service tests
pass. Mac Local and signed Mac iCloud Dev builds pass, as does iPhone
app/UI-test compilation. The generated iPhone background mode and signed Mac
APNs entitlement were inspected. No physical push-delivery result is claimed.

[scheduling-ci]: https://github.com/AndreasSko/meh.md/actions/runs/34759050114

The first owner scheduling check reported automatic receipt on iPad, while
Mac required Sync Now. The Mac log confirmed successful APNs registration
and automatic local uploads; incoming changes were delivered during the
manual fetch. Fetch events now record their scheduled/manual origin so a
manual result cannot be mistaken for notification-triggered delivery. Mac
automatic receiving remains an owner checkpoint. No engine-state reset or
unverified notification workaround is introduced.

The larger local matrix passes all eight disruption seeds and 100/500/1,000
synthetic notebooks. The 1,000-note debug run took 515.2 seconds for initial
replication and 15.3 seconds for an incremental exchange. These expose a
performance follow-up, not a CloudKit latency claim; full measurements and
boundaries are in the [validation record](notebook-sync-validation.md).
