# Milestone plan

Updated: 2026-09-12

## Current state

- Product scope and initial plan are documented.
- No app code, editor prototype, or sync implementation exists yet.
- No builds or device tests have been performed.
- Next: milestone 0. Implementation has not started.

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

Status: not started.

### Work

- Investigate how FSNotes styles Markdown and how coupled the useful code is to
  its app. Compare selective reuse with a small native text-view
  implementation; record licensing obligations if reusing code.
- Prefer literal Markdown text with styling for the first editor. Build a small
  sample before committing to a rendering approach.
- Establish an app skeleton for macOS and a universal iPhone/iPad app, with
  shared document logic.
- Finalize the minimum document/persistence boundary needed to avoid replacing
  a throwaway storage model when adding sync.

### Acceptance

- The app builds for macOS and iOS/iPadOS with reproducible commands recorded
  in the repository.
- A basic editor can be exercised on Mac and in iPhone/iPad simulator layouts.
- The editor choice, explicit deployment targets, and unresolved risks are
  documented.
- No real notes are imported or modified.

## 1 — One pleasant, durable note

Status: not started; depends on milestone 0.

### Work

- Implement headings, emphasis, lists, links, and code styling while retaining
  visible syntax.
- Persist edits locally and maintain an ordinary Markdown copy.
- Materialize that copy in the platform's documented user-visible location and
  detect external changes without importing or destroying them.
- Establish basic selection, copy/paste, native undo, and a recovery strategy.

### Acceptance

- A note survives closing/reopening and an interrupted save without losing
  acknowledged edits.
- Markdown output matches the saved document text and can be regenerated after
  interruption.
- Styling does not change source text or create formatting-only undo entries.
- Basic typing and undo work with emoji, accented text, and multiline pastes.
- The owner can try the editor on Mac, iPhone, and iPad; unperformed device
  checks remain explicitly open.

## 2 — Prove synchronization early

Status: not started; depends on milestone 1.

### Work

- Prototype Automerge with CloudKit/CKSyncEngine for the same note across
  devices.
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

Status: not started; depends on milestone 2.

### Work

- Add multiple notes and nested folders, including create, rename, move, and
  trash.
- Import a copy of the existing Markdown library while preserving paths and
  content.
- Define and test rename collisions, folder moves, and delete-versus-edit
  behavior.

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
