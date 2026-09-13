# Milestone plan

Updated: 2026-09-13

## Current state

- Product scope and initial plan are documented.
- A basic multiplatform Xcode project exists for macOS, iPhone, and iPad.
- A literal-Markdown editor spike exists and has passed macOS and generic iOS
  simulator builds. Its macOS editing checks are recorded separately.
- The Automerge spike validates Unicode, history through file replacement,
  local merges, and interrupted saves. Real native adapter tests pass on
  macOS and iOS after a targeted macOS undo callback correction.
- A production single-note core now saves serialized Automerge files, tracks
  saved state with heads, and supports explicit previous-file recovery. The
  app exposes one editing window/scene. The managed Markdown copy is
  implemented and its signed Mac app checks passed. Sync remains open.
- The editor has been visually checked in iPhone and iPad simulators. The owner
  has exercised editing and undo on a physical iPhone; iPad device interaction
  remains open.
- The editor direction is recorded: SwiftUI hosts thin native text views,
  both explicitly using TextKit 2, while syntax detection and later document
  behavior remain shared. Paint-only styles use rendering attributes; font
  styles use undo-suppressed text-storage attributes.
- The document boundary is recorded: shared document state is authoritative,
  while Markdown files are derived copies maintained by a separate writer.
- Editor styling is implemented, with 14 macOS native editor tests passing.
- The iPhone 17 simulator save/reopen and Files checks passed. Physical-device
  acceptance remains separate. Milestone 1 is complete; sync is next.
- Milestone 2 now has shared durable replication, local test transports,
  revision-aware native editing, and a CloudKit adapter awaiting live setup.
  The iPhone/iPad localhost handoff and exact Markdown-copy checks passed.
  See [sync verification](sync-verification.md) for evidence and open work.

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

Status: core and replication implemented on 2026-09-13; app wiring follows a
behavior review checkpoint. See the [execution plan](milestone-3-plan.md).

### Work

- Add multiple notes and nested folders, including create, rename, move, and
  trash.
- Import a copy of the existing Markdown library while preserving paths and
  content.
- Define and test rename collisions, folder moves, and delete-versus-edit
  behavior.
- Replace fixed foreground polling with CloudKit scheduling and change
  notifications. Batch local uploads, retain activation/manual refresh, and
  measure responsiveness and battery impact as the note count grows.
  Milestone 2 already establishes retry-after handling and durable pending
  work; production background delivery belongs to this scheduling work.

### Acceptance

- Hundreds of notes in subdirectories can be imported and navigated
  comfortably.
- Import leaves source files untouched and preserves unsupported Markdown
  syntax.
- Folder/note operations synchronize consistently across all three devices.
- Concurrent deletion and editing leave edited content recoverable.

## 4 — Daily-use hardening

Status: not started; depends on milestone 3.

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
