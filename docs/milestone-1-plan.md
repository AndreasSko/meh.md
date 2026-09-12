# Milestone 1 execution plan

Prepared: 2026-09-12
Status: styling and one-way copies implemented; signed Mac copy checks passed.
The iPhone simulator save/reopen and Files checks passed. Closure is deferred.

## Outcome and scope

Deliver one pleasant, durable note on Mac, iPhone, and iPad. The shared
document state is authoritative. A separate writer maintains an ordinary
UTF-8 Markdown copy in the location defined by the architecture.

Begin with a bounded local Automerge spike before further editor work. If it
passes, persist serialized Automerge documents directly to internal files.
There is no SQLite database, custom journal, or temporary document format to
migrate later. The spike must validate the exact APIs and safe-write procedure
before the app relies on them.

This refines milestone 1 in [the milestone plan](plan.md) and follows
[ADR 001](decisions/001-native-text-editor.md) and
[ADR 002](decisions/002-document-persistence-boundary.md).

Included: document identity and edit operations, local persistence, basic
recovery, safe Markdown materialization, visible save status, complete styling
for the agreed syntax subset, and native editing checks.

Deferred: CloudKit and device synchronization, multiple notes, folders, import,
external-edit ingestion or file watching, syntax hiding, advanced remote undo,
and a full recovery-history browser. A portable copy is not an independent
backup; full-library export remains later product work.

## Starting point before implementation

- Milestone 0 is merged at `b25f920`; the working tree was clean when
  inspected.
- `ContentView.swift` owns an in-memory sample through `@State`.
- `MyApp.swift` uses `WindowGroup`; separate windows currently own separate
  text values. The durable note must have a shared owner or one editing window.
- `MarkdownEditor.swift` contains thin TextKit 2 AppKit and UIKit adapters.
  They currently report whole strings and defer updates during composition.
- `MarkdownSyntax.swift` uses a small regex-based syntax detector. Fenced code,
  reliable exclusion of syntax inside code, and broader edge cases need work.
- `MarkdownPresentation.swift` separates rendering and layout attributes.
  Headings are still body-sized, and parsing repeats during presentation.
- The project has a standalone syntax check, but no dedicated test target.
- macOS user-selected file access is currently read-only. No local store,
  Markdown writer, folder bookmark, or Files exposure is implemented.

## Execution steps

### 1. Test Automerge locally before continuing the editor

**Status:** follow-up validation completed on 2026-09-12. See the
[spike report](automerge-spike.md) for evidence and limitations.

The actual macOS adapter probe found missing undo delivery to the binding.
The owner approved a scoped UndoManager completion observer. Real adapter
tests now pass on macOS and iOS, including marked text and exact Unicode.

- Inspect the current official Automerge Swift API and pin the tested version.
  Verify integration and builds for macOS and iOS, with no CloudKit setup.
- Create one document with stable note identity and collaborative text. Apply
  range edits to literal Markdown, including emoji, decomposed accents, and
  multiline text. Verify native UTF-16 conversion against its text indexing.
- Serialize the complete document to an internal file and reload it. Verify
  exact text, identity, and usable merge history, rather than exporting text
  into a new document on every save.
- Fork a common document into two independent local replicas. Edit both, merge
  in both directions, and verify convergence, preservation of separate edits,
  repeat-merge behavior, and documented same-position outcomes. Repeat after
  saving and reloading the replicas; validate replica actor identities.
- Prototype safe file replacement and retention of a previous known-good
  serialized document. Inject failures and terminate a separate writer process
  around save boundaries. Reopen and inspect the resulting files.
- Use a minimal probe of the existing native editor adapters to verify edits,
  undo, and redo through the document boundary. This is compatibility testing,
  not further styling or product editor development.
- Measure serialization size and save latency for a representative note and
  repeated edits. Start with full-document saves; add complexity only if
  measured behavior demonstrates a need.

**Checkpoint:** record the tested dependency, commands, outcomes, limitations,
and recommended file-saving procedure. Local merges do not establish reliable
device synchronization. If text editing, undo, or persistence has a blocking
problem, report it and revise the approach before continuing editor work;
do not silently substitute SQLite or a temporary storage model.

### 2. Define the file durability and recovery contract

**Status:** recorded in the contract and ADR 003.

The [durability contract](durability-contract.md) and
[ADR 003](decisions/003-automerge-save-state.md) define these choices:

- A stable note ID, a schema version, and Automerge heads identifying each
  captured document state. Do not introduce a separate revision counter.
- An edit is acknowledged as saved only after its authoritative local commit
  succeeds. Visible typing may precede that commit and must remain unsaved in
  the UI until then. Saving must not depend solely on app termination hooks.
- A failed save retains the in-memory edit and reports failure. An older save
  completion cannot mark a newer edit saved or replace its text.
- Keep sufficient local bookkeeping to recognize an outdated Markdown copy
  after restart. Settle its minimum representation and write ordering; do not
  assume separate file replacements form one atomic transaction.
- Recovery preserves the note ID, retains known-good content, and never
  silently replaces unreadable stored state with a fresh sample note.
- Distinguish process interruption from sudden power loss. Define the supported
  durability guarantee and verify the selected storage configuration.

Use the spike-validated Automerge serialization in Application Support, owned
by one serialized file-storage component. The two primary representations are
the authoritative Automerge file and its derived Markdown copy; a previous
known-good internal file and minimal local bookkeeping support recovery.
Do not add a database, custom journal, or speculative upload queue.

Choose a small, explicit recovery retention policy and a basic way to retrieve
or restore a retained version. Restoring creates a new change in the same
note. Preserve Automerge identity and history; recovery must not recreate the
document from its Markdown copy. Distinguish fallback after damaged storage
from restoring older content as a new edit, and report any fallback data loss.

**Checkpoint:** document the file layout, durable-save boundary, recovery
policy, and failure cases before delegating dependent implementation.

### 3. Build the Automerge-backed core and test harness

**Status:** implemented in `Sources/NoteCore`, with controlled storage tests.

- Introduce a document model, an app-owned editing session, a local-store
  interface, and explicit save/materialization states. Reuse the validated
  spike behind this interface; the editor does not call Automerge directly.
- Apply current editor snapshots synchronously in the owning session. Convert
  UTF-16 ranges for explicit range edits and reject invalid boundaries. If a
  later asynchronous producer submits edits, require expected Automerge heads
  so stale offsets cannot target a different state.
- Keep native undo in the text views; undo and redo submit ordinary text edits
  to the same core. Do not add a competing core undo stack.
- Make ownership and concurrency explicit, accounting for the project's
  default MainActor isolation. Keep blocking persistence off the editor path.
- Add a focused automated test target with temporary storage and controlled
  failure injection. Verify both Apple platform builds.

**Checkpoint:** test exact text preservation, Unicode replacements, snapshot
identity, stale edits, and initial-load behavior without a native view.

### 4. Make authoritative file saves and recovery work

**Status:** implemented; fault and recovery tests pass. Real process-kill
evidence remains in the spike; production storage tests inject failures.

- Implement the validated serialized-document load/save procedure, schema
  initialization, and previous known-good file retention. Distinguish first
  launch from missing or damaged state.
- Serialize commits and make pending materialization recoverable. If saves are
  coalesced, track precisely which heads each completion acknowledges.
- Handle write failures and unavailable storage without reporting success or
  discarding the current editing buffer.
- Add the minimum recovery action defined in step 2; retain damaged data for
  inspection instead of overwriting it during recovery.

**Checkpoint:** after a successful save, a fresh store instance loads exactly
that state or a descendant containing its changes. Exercise failures before
commit, during commit, and after commit but before acknowledgment or Markdown
writing.
Also exercise real process termination; distinguish it from mocked failures.

### 5. Connect the editor and deliver the first usable slice

**Status:** implemented; Mac app save/undo/quit/reopen verified. The iPhone 17
simulator app save/reopen and Files checks passed, alongside the earlier native
adapter tests. Physical-device acceptance remains separate.

- Replace the runtime sample state with the shared session. Keep sample text
  in previews or explicit test fixtures.
- Load before enabling editing so delayed startup cannot overwrite new input.
- Route typing, selection replacement, paste, undo, redo, and completed IME
  composition through the core. Verify composition reaches the saved state.
- Keep save callbacks from replacing native text or disturbing undo/selection.
- Resolve multiple-window ownership explicitly. Prefer one editing window for
  this milestone if sharing edits safely would introduce remote-update scope.
- Show compact states for unsaved changes, locally saved content, save failure,
  and separately pending or failed Markdown-copy updates.

**Checkpoint:** type, undo, save, quit, and reopen one note on macOS and the
iOS simulator. Slow and failed saves must not regress text or show false
success. This is the first owner-testable increment.

### 6. Maintain the portable Markdown copy safely

**Status:** implementation, fault tests, and signed Mac app checks passed.
The one-way, read-only copy policy is approved. See the
[copy contract](markdown-copy-contract.md).

- Use a macOS-selected local folder outside iCloud Drive, read/write sandbox
  access, and a persisted security-scoped bookmark. Handle stale bookmarks,
  missing folders, moved folders, and access failures with a reconnect action.
- Use the app's Documents directory on iPhone/iPad and expose the copy in
  Files. Keep internal storage and recovery data outside that public directory.
- Use a stable managed filename for this one note. Never claim or replace an
  unrelated existing file on first materialization.
- Write from a persisted snapshot, using staged replacement and persisted
  bookkeeping. Retry after restart, including a crash after file replacement
  but before recording successful materialization.
- Track the last managed bytes/fingerprint and the attempted snapshot heads.
  On publish, activation, and reopen, overwrite external edits to the managed
  copy and recreate it after deletion. Do not introduce continuous watching.
- Do not ingest external edits or create conflict copies. Describe the managed
  copy as read-only product output without claiming operating-system write
  protection.
- Evaluate coordinated access and replacement races explicitly. Test changes
  during a write and confirm that the latest authoritative snapshot wins.

**Checkpoint:** compare exact UTF-8 bytes with saved text. Test missing copies,
existing unrelated files, overwritten external edits, recreated deletions,
inaccessible destinations, and interruption at each write/bookkeeping
boundary. These failures must never prevent authoritative local saving.

### 7. Finish the agreed editor styling

**Status:** implemented; 14 macOS native editor tests pass, including 11 new
styling tests. Mac visual and undo checks passed. Further iOS checks are
deferred; the milestone remains open.

- Define fixtures for headings, strong/emphasis, ordered/unordered lists,
  inline links, inline code, and fenced code, including incomplete syntax while
  typing, escapes, nesting, and Unicode.
- Add larger heading metrics with a stable base font. Preserve literal markers
  and ensure typing after headings or code returns to the right style.
- Give code precedence over Markdown-like content inside it, for both font and
  paint attributes. Do not grow this into full rendered Markdown support.
- Preserve selection, composition, native paste, and undo while styles refresh.
- Reuse syntax results per text revision where appropriate. Check one longer
  representative note before deciding whether incremental parsing is needed.

**Checkpoint:** automated fixtures verify spans and source preservation;
native checks verify layout, selection, and absence of formatting-only undo.
Include light/dark appearance, text sizing, and iPad hardware-keyboard use.

### 8. Review failures and test on devices

- Run the focused core/store/writer tests and macOS/iOS builds. Run native
  editor regressions on both adapters.
- Independently review acknowledgment ordering, startup recovery, projection
  races, error handling, schema handling, and preservation of note identity.
- Have the owner exercise Mac, physical iPhone, and physical iPad: writing,
  multiline paste, emoji, accents, undo/redo, close/reopen, and Files/Finder
  access. Test disconnecting/reconnecting the Markdown destination where
  applicable.
- Record automated checks, simulated failures, actual process interruptions,
  and physical-device observations separately. Leave unperformed checks open.

**Checkpoint:** every milestone 1 acceptance item has evidence or an explicit
remaining limitation; a passing build alone does not establish durability.

### 9. Close out and prepare milestone 2

- Update `docs/plan.md`, architecture notes, and README with delivered
  behavior, storage locations, recovery instructions, results, and limitations.
- Record how milestone 2 will exchange and merge changes in the existing
  Automerge documents through the shared core. Preserve the local file store
  and Markdown writer where practical. CloudKit transport, durable delivery
  bookkeeping, and actual device handoff remain milestone 2 work.
- Keep commits coherent: core/durability, editor integration, Markdown copies,
  styling, and final evidence as appropriate. Include relevant tests with each
  behavior; fix up mistakes within the owning commit before final review.

## Suggested sub-agent use during implementation

The main task owns the contract, app/editor integration, Xcode project changes,
final review, and device-test coordination. During the spike, a bounded agent
can independently inspect merge/indexing behavior while the main task tests
serialization and interruption. Review the combined evidence before moving on.
After step 3 establishes shared interfaces, use bounded assignments with
explicit file ownership:

- **Persistence agent:** Automerge file storage, recovery, and fault tests.
- **Styling agent:** syntax/presentation refinements and their fixtures.
- **Writer agent:** Markdown materialization and external-change tests, after
  the persisted-snapshot interface and storage bookkeeping are settled.

Run only independent assignments concurrently. Keep `MarkdownEditor.swift`,
app entry points, and the Xcode project under the main task's ownership. An
independent review agent can audit persistence and writer failure behavior
after those implementations exist. Integration and verification remain the
main task's responsibility.

## Continuation instruction

Read this plan, the spike report, and the accepted decisions. The owner has
deferred milestone closure. The iPhone simulator save/reopen and Files checks
have passed. Continue review follow-ups and the recorded remaining device
checks within this milestone. Use the durability contract and scalar Automerge
text with tested UTF-16 conversion at the editor boundary. Use the validated
file-based approach, without SQLite. Implement in small verified increments
and use bounded sub-agents where their dependencies are settled. Do not advance
milestone 1 to complete without recording the acceptance evidence and
outstanding device checks.
