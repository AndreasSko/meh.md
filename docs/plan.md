# Milestone plan

Updated: 2026-09-13

## Current state

Milestones 0-3 delivered a native Markdown editor, Automerge-backed local
saving, a sync transport, and a notebook with folders, import, Markdown copies,
Trash, permanent deletion, and automatic sync scheduling. Milestone 3 closed
on 2026-09-13; its [closeout record](milestone-3-plan.md) preserves review and
validation evidence.

Daily-use hardening is next. [Sync-pause recovery][issue-22] and
[Mac automatic receiving][issue-24] are explicit follow-ups. GitHub issues
track ongoing work; completed implementation milestones do not imply complete
physical-device acceptance. Earlier single-note checks remain historical
evidence, and physical iPad interaction still needs validation.

See the [architecture](architecture.md) for the implemented design and the
[documentation index](README.md) for contracts and verification records.

## Working method

Start a task for a coherent milestone or
bounded part of one; continue fixes in that task while the objective stays the
same. Fresh tasks should read this document, the product brief, and
architecture notes rather than relying on conversation history.

For each milestone:

1. Refine its implementation steps and acceptance criteria before substantial
   work.
2. Implement, build, and run relevant checks; resolve failures within scope.
3. Review important persistence and sync changes separately from their
   implementation.
4. Have the owner try the resulting build on relevant devices.
5. Update this document with verified results, remaining limitations, and the
   next action.

Automated tests and real-device checks are different evidence. Record them
separately. Later milestones remain rough until earlier work resolves the
important unknowns.

## 0 — Foundation and editor investigation

Status: complete on 2026-09-12.

### Work

- Reconcile the milestone with the existing multiplatform Xcode project. A
  separate toolchain, SDK, simulator, and signing audit is not part of the
  current editor tranche.
- Inspect the current FSNotes editor sources, dependencies, license, and
  text-range strategy. Identify which parts, if any, can be reused
  independently and record obligations that copying code would introduce.
- Compare selective FSNotes reuse with a thin native editor built on
  `NSTextView` and `UITextView`. Consider literal-source preservation,
  range/index conversion, composition, selection, undo, cross-platform
  sharing, dependencies, coupling, and licensing.
- Build the smallest native editor spike in the existing project. Keep its
  backing value as literal Markdown and style a deliberately small syntax
  sample without inserting attachment characters or rewriting the source.
- Exercise plain typing, selection replacement, multiline paste, emoji,
  accented text, and undo/redo. Do not add persistence, synchronization,
  folders, or the complete milestone 1 syntax set to the spike.
- After the spike is evaluated, finalize the minimum document and persistence
  boundary needed to avoid replacing a throwaway storage model when sync is
  added.

### Acceptance

- The FSNotes revision inspected, relevant source paths, dependencies, license,
  and any attribution obligations are recorded.
- A comparison explains whether selective reuse or a thin native wrapper is
  preferred without treating FSNotes as a drop-in dependency.
- The existing app contains a basic literal-Markdown editor whose displayed
  styling does not change its backing source text.
- Focused checks cover ASCII Markdown, emoji, accented text, and multiline
  source. Manual spike notes distinguish observed selection, composition, and
  undo/redo behavior from anything not yet verified.
- The editor direction, explicit deployment targets, and unresolved risks are
  documented before the milestone is completed.
- No real notes are imported or modified.

## 1 — One pleasant, durable note

Status: complete on 2026-09-12.

See the revised [step-by-step execution plan](milestone-1-plan.md) for scope,
implementation checkpoints, and sub-agent assignments.

### Work

- The [Automerge spike](automerge-spike.md) follow-up validates history through
  interrupted file saves and automatic native undo integration.
- The Automerge-backed core and internal file persistence are implemented,
  retaining a previous known-good version for explicit recovery.
- Headings, emphasis, lists, links, and code styling are implemented while
  retaining visible syntax.
- Persist edits locally and maintain a managed, one-way Markdown copy.
- Materialize that copy in the platform's documented user-visible location.
  Overwrite external edits to the managed copy and recreate deletions without
  ingesting either as document changes.
- Establish basic selection, copy/paste, native undo, and a recovery strategy.

### Acceptance

- The Automerge spike records tested APIs, local merge outcomes, file recovery
  behavior, and editor compatibility before further editor development.
- A note survives closing/reopening and an interrupted save without losing
  acknowledged edits.
- Markdown output matches the saved document text and can be regenerated after
  interruption.
- Styling does not change source text or create formatting-only undo entries.
- Basic typing and undo work with emoji, accented text, and multiline pastes.
- The owner can try the editor on Mac, iPhone, and iPad; unperformed device
  checks remain explicitly open.

## 2 — Prove synchronization early

Status: Mac/iPhone physical acceptance and iPad simulator convergence verified.
Physical iPad checks remain open as follow-up validation.
PR #6 and stacked PR #7 are merged as of 2026-09-13.

See the [execution plan](milestone-2-plan.md). Prove the shared coordinator
against a deterministic service and two simulator apps before iCloud device
acceptance. The production transport boundary is pluggable; the local service
models remote record storage without simulating Apple account services.

### Work

- Add CloudKit/CKSyncEngine transport to the existing Automerge document core
  for the same note across devices.
- First establish immutable snapshot exchange, durable bootstrap proposals,
  account/workspace binding, and local record-store adapters.
- Exercise offline replicas, lost acknowledgments, remote native editing, and
  rollback recovery with a replay checkpoint tied to document history.
- Persist pending uploads and received changes safely across restarts.
- Add a small sync-status display and record actual device-handoff behavior.

### Acceptance

- Edits converge across Mac, iPhone, and iPad after offline work and
  reconnecting.
- Duplicate delivery, interrupted upload/download, and app restart do not lose
  acknowledged edits.
- Concurrent edits at separate positions are retained; same-position outcomes
  are inspected and documented.
- Local writing remains available when sync fails, and failure/pending states
  are distinguishable.
- Device-handoff latency is measured under normal use and assessed by the
  owner; no fixed latency guarantee is assumed.

## 3 — A usable notebook

Status: implementation complete; reviewed PRs #14, #16, and #18 merged on
2026-09-13. See the [execution and closeout record](milestone-3-plan.md).
Outstanding recovery and device validation are tracked in GitHub issues.

### Work

- Add multiple notes and nested folders, including create, rename, move, and
  trash.
- Import a copy of the existing Markdown library while preserving paths and
  content.
- Define and test rename collisions, folder moves, and delete-versus-edit
  behavior.
- Publish active notes to the app-owned structured Markdown hierarchy without
  ingesting external edits. Preserve earlier single-note copies without
  maintaining them.
- Replace fixed foreground polling with CloudKit scheduling and change
  notifications. Batch local uploads, retain activation/manual refresh, and
  measure responsiveness and battery impact as the note count grows.
  Milestone 2 already establishes retry-after handling and durable pending
  work. Deterministic local and CI coverage exercises sync without iCloud;
  actual APNs delivery remains a physical-device check.

### Acceptance

- Hundreds of notes in subdirectories can be imported and navigated
  comfortably.
- Import leaves source files untouched and preserves unsupported Markdown
  syntax.
- Folder/note operations synchronize consistently across all three devices.
- Concurrent deletion and editing leave edited content recoverable.
- Existing activated notebooks reopen offline. A fresh cloud installation
  joins the canonical version 2 notebook online.

## 4 — Daily-use hardening

Status: ready to start after milestone 3; implementation not started.
GitHub issues are authoritative for follow-up scope and progress.

Start with [persisted sync-pause recovery][issue-22], then complete
[Mac automatic-receiving verification][issue-24]. Track
[offline export and restore][issue-20], [replication performance][issue-21],
and [Markdown fidelity fuzzing][issue-23] in their existing issues.

### Work and acceptance

- Exercise recovery versions and trash restore, including restart after a
  failed Markdown write.
- Test prolonged offline use, a fresh-device download, unavailable iCloud,
  quota failures, and account transitions with appropriate test fixtures or
  device checks.
- Ensure an account switch cannot upload the previous account's notes into the
  new account automatically.
- Use a copied library for daily writing; fix observed editor, performance, and
  sync problems before adopting the app as the primary notebook.
- Profile and improve large-notebook replication. The Milestone 3 synthetic
  1,000-note debug run took 515.2 seconds for initial replication and 15.3
  seconds for an incremental exchange. Compare release builds, investigate
  replica application and Automerge decoding/merging, and retain the existing
  convergence and durability tests. These are local synthetic measurements,
  not CloudKit or device latency; see the
  [validation record][scale-validation].

[scale-validation]:
  notebook-sync-validation.md#recorded-synthetic-run-2026-09-13

## 5 — Optional editor refinement

Status: deferred; requires an explicit product decision after daily use.

- Reveal/hide syntax around the cursor.
- Refine cursor and selection preservation during remote updates.
- Improve undo behavior across synchronization beyond the documented initial
  behavior.

Do not pull these into earlier milestones unless needed to fix basic
correctness.

## Completion record

For each completed milestone, append a short entry with its date, commit,
delivered behavior, automated checks, actual device checks, known limitations,
and next step. A passing build alone does not establish reliable
synchronization.

### Milestone 0 — 2026-09-12

- **Commits:** `1f3519a`, `f952a9e`, and `0c4be68` in PR #3, followed by this
  documentation closeout.
- **Delivered:** Multiplatform project foundation, literal-Markdown TextKit 2
  editor spike, shared syntax detection, FSNotes investigation, and accepted
  editor and document-boundary decisions.
- **Automated checks:** macOS and generic iOS Simulator builds, Unicode and
  nested-style syntax checks, clean-diff checks, and a focused macOS native
  undo probe.
- **Device checks:** macOS editing and undo, iPhone and iPad simulator
  presentation, and owner-tested editing and undo on a physical iPhone.
- **Known limitations:** No persistence or synchronization yet; larger heading
  metrics, long-document optimization, IME behavior, external model updates,
  and physical iPad interaction remain deferred or unverified.
- **Next:** Milestone 1 implements one durable note behind the accepted shared
  document boundary and maintains its derived Markdown copy.

### Milestone 1 — 2026-09-12

- **Delivery:** PR #5, including simulator regression commit `1440dc6`.
  Milestone completion records delivered scope; PR merge is tracked separately.
- **Delivered:** One native Markdown note with Automerge-backed local saves,
  saved-state feedback, explicit previous-file recovery, managed Markdown
  copies, and the agreed visible-syntax styling. No SQLite or network sync.
- **Automated checks:** 47 core and 14 Mac native editor tests; 20 Automerge
  spike tests; 3 iOS native adapter tests; 1 iPhone simulator app persistence
  test. Real spike process kills exercised four save boundaries. Mac and iOS
  builds passed. See [verification](local-note-verification.md).
- **App checks:** Mac typing, undo, save/reopen, folder selection, bookmark
  restoration, copy overwrite and recreation. iPhone simulator Unicode text,
  save/relaunch, exact copy bytes, and Files preview passed.
- **Known limitations:** Physical iPhone/iPad persistence acceptance, iPad
  hardware-keyboard checks, and install/restore behavior remain open. No
  sudden-power-loss guarantee, multiple notes, folders, import, or sync.
- **Next:** Start milestone 2 with a bounded CloudKit/CKSyncEngine transport
  spike. Prove durable delivery, offline convergence, and remote editor updates
  for one note before expanding the data model. Carry device checks forward.

[issue-20]: https://github.com/AndreasSko/meh.md/issues/20
[issue-21]: https://github.com/AndreasSko/meh.md/issues/21
[issue-22]: https://github.com/AndreasSko/meh.md/issues/22
[issue-23]: https://github.com/AndreasSko/meh.md/issues/23
[issue-24]: https://github.com/AndreasSko/meh.md/issues/24
