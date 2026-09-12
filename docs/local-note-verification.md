# Local note implementation and verification

Date: 2026-09-12
Scope: milestone 1 steps 1 through 5, before portable Markdown copies.

## Implemented behavior

- `Sources/NoteCore` owns the Automerge document, editing session, immutable
  snapshots, and serialized file store. The editor submits text to the session.
- The app opens one note and saves it automatically. Saved status compares
  current Automerge heads with the successfully written snapshot's heads.
  A completed older write cannot overwrite or acknowledge newer typing.
- Save failures retain open text and offer retry. Loading and recovery keep
  editing disabled. An unsupported schema never falls back to an older file.
- Storage retains `note.automerge` and `note.previous.automerge` under the
  app's Application Support `Notes` directory. Explicit recovery preserves
  damaged data as `note.quarantine-<UUID>.automerge` and warns of newer loss.
- macOS uses a single `Window`; the iOS scene manifest disables multiple
  scenes. Native views continue to own undo and composition.
- macOS UndoManager completion observers bridge undo/redo that did not reach
  the ordinary delegate callback. UIKit uses its existing native callbacks.

## Automated evidence

- Root `swift test --disable-sandbox`: 21 core tests and 3 actual native
  editor integration tests passed on macOS.
- The same 3 native adapter tests passed on an iPhone 17 iOS 27 simulator:
  typing/undo/redo, marked-text completion, and exact Unicode replacement.
- Core tests cover slow saves while typing, failed saves and retry, repeated
  load calls, document history, snapshot metadata, schema compatibility,
  missing/unreadable/damaged files, and interrupted recovery retries.
- The spike's separate writer was killed at four write boundaries. Each case
  reopened and edited the saved history, then merged an earlier offline fork.
  See [the spike report](automerge-spike.md) for commands and measurements.
- The app builds for macOS and iOS Simulator using Xcode 27 with
  `CODE_SIGNING_ALLOWED=NO`.

## App checks

- Mac: opened an empty note, entered Markdown with precomposed/decomposed
  accents and emoji, observed saved status, typed and undid an additional
  character through the Edit menu, quit, and reopened the reviewed build.
  The reopened view showed the saved text. Parsing the persisted Automerge
  file independently verified its exact UTF-8 bytes.
- The unsigned Mac check used `~/Library/Application Support/Notes`.
  A signed sandboxed app resolves Application Support inside its container;
  signed distribution behavior was not established by this unsigned check.
- The iOS Simulator app save/reopen interaction remains open. Its build and
  native adapter tests passed; these do not substitute for that app check.
  Installation and launch on iPhone 17 succeeded. Computer Use could not
  resolve Simulator, and opening Device Hub did not return before it was
  aborted. No simulator test text was entered or existing data erased.

## Remaining work and limits

- The portable Markdown copy, external-change handling, and styling are the
  next milestone increments. There is no CloudKit transport or device sync.
- Production file tests inject interruption stages in-process. Real SIGKILL
  history evidence belongs to the spike, whose file procedure the core uses.
  No sudden-power-loss guarantee is established.
- Programmatic marked-text probes are useful integration evidence but do not
  replace interactive testing with physical keyboards and input methods.
- Owner checks on physical iPhone and iPad, signed sandbox behavior, and
  longer-note release-build/device latency remain open.

The [durability contract](durability-contract.md) and
[execution plan](milestone-1-plan.md) define the continuation boundary.
