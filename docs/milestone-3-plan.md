# Milestone 3: a usable notebook

Started: 2026-09-13. First branch: `codex/milestone-3-notebook-core`.

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

Next: implement notebook-wide replication before UI integration.
