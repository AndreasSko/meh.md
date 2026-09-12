# Local note implementation and verification

Date: 2026-09-12
Scope: milestone 1 local persistence, styling, and managed Markdown copies.

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
- The agreed styling subset now includes larger headings, emphasis, lists,
  links, inline code, and fenced code. Code takes precedence over syntax-like
  contents; source markers remain visible. This is not a full CommonMark
  parser.
- Markdown copy integration includes separate status, persisted snapshots,
  Mac folder bookmarks, and iOS Files exposure. The approved policy
  treats copies as one-way, read-only product outputs: external edits are
  overwritten and deletions recreated, without ingestion or conflict copies.
  An unrelated initial `note.md` remains protected. See the
  [copy contract](markdown-copy-contract.md).

## Automated evidence

- Root `swift test --disable-sandbox`: 47 core tests and 14 native editor
  tests passed on macOS. The styling tests cover syntax precedence,
  heading metrics, light/dark colors, selection, and native undo preservation.
- The copy tests include 15 writer and 11 controller cases. They verify
  overwrite/recreation, initial collisions, partial staged writes, interruption
  at five boundaries for both first creation and updates, and newer snapshots
  arriving during an older write, an unreadable sparse 1 TiB initial collision,
  and multi-chunk Unicode hashing.
- The separate Automerge spike suite passed all 20 tests. Its interruption
  script also verifies a completed recovered write and retained damaged bytes.
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
- A signed Mac build contains sandbox, user-selected read/write, and scoped
  bookmark entitlements. Runtime bookmark restoration was also checked as
  described below. iOS simulator runtime checks are recorded below.
- The final signed Mac build and unsigned iOS Simulator compilation both
  passed after the one-way copy policy changes, without compiler warnings.

## Repeatable iOS app test

`meh.mdUITests/NotePersistenceUITests.swift` passed on iPhone 17 / iOS 27:
it preserved the original note, appended unique ASCII and Unicode text,
waited for both save statuses, terminated the app, and verified exact text
and statuses after relaunch. The result bundle reports 1 passed, 0 failed.
Independent comparison of `Documents/note.md` matched all 185 UTF-8 bytes.

Run against a booted simulator, substituting its UDID:

```sh
xcodebuild -project meh.md.xcodeproj -scheme meh.md \
  -destination 'id=<simulator-UDID>' \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO test \
  -only-testing:meh.mdUITests/NotePersistenceUITests
```

Disable parallel testing for this existing-data check. The initial parallel
run cloned the simulator and copied stale destination folder identity;
the app correctly requested reconnection. The original simulator passed
without any product change. Install/restore behavior remains a separate
acceptance case. The test appends a unique section to the simulator note.

## App checks

- Mac: opened an empty note, entered Markdown with precomposed/decomposed
  accents and emoji, observed saved status, typed and undid an additional
  character through the Edit menu, quit, and reopened the reviewed build.
  The reopened view showed the saved text. Parsing the persisted Automerge
  file independently verified its exact UTF-8 bytes.
- The unsigned Mac check used `~/Library/Application Support/Notes`.
  A signed sandboxed app resolves Application Support inside its container;
  signed distribution behavior was not established by this unsigned check.
- Mac styling was checked visually in dark appearance, including literal
  syntax within a fenced block. Typing after the block used body styling;
  undoing an added character returned to the expected saved text.
- With owner-approved launch of the signed Mac build, selected an empty
  temporary folder through the native picker. Native paste updated the note
  and copy with precomposed/decomposed accents and emoji; independent byte
  comparison verified the exact 49-byte UTF-8 output.
- Changed only that disposable Markdown copy externally, quit, and relaunched
  the app. The folder bookmark restored without another picker, the note
  retained its saved text, the copy reported up to date, and its bytes again
  matched the authoritative test text. Deleting only the test copy and
  relaunching recreated the same exact bytes. No conflict files were produced.
- A release-optimized parser probe averaged 5.63 ms for about 15 KB across
  100 sections. This is a Mac parsing measurement, not device typing latency.
- iPhone 17 / iOS 27: built, installed, and launched through `xcodebuild` and
  `simctl`. Device Hub became accessible after quitting stuck GUI processes
  and opening its `Contents/MacOS/DeviceHub` executable through macOS `open`.
  Starting that executable directly from a shell did not fix discovery.
- Entered a Unicode note through the accessibility control and committed it
  through a native keystroke. The app reported Saved and an up-to-date copy;
  independent comparison verified its exact 61 UTF-8 bytes. After terminating
  the app with `simctl` and relaunching, the editor retained the same text and
  statuses. Files displayed `meh.md/note.md`, and Quick Look showed its text.
  No simulator data was erased and no physical device was used.

## Review follow-up

- The second CodeRabbit review prompted narrower error handling in the UI,
  bounded Markdown-copy inspection, and clearer copy error messages. The
  spike also separates malformed schema data from unsupported versions and
  preserves damaged
  current bytes before a recovered write. Both stores sync the previous-file
  rename before replacing the current file; this is not power-loss evidence.
- The reported schema/encoding downgrade path did not reproduce with pinned
  Automerge 0.7.2: a document created with UTF-8 indexing reloads using
  Unicode-scalar indexing. The core validation order is unchanged; its
  existing future-schema storage test confirms that fallback is blocked.

## Remaining work and limits

- Mac copy selection, updates, scoped-bookmark restoration, overwrite, and
  recreation checks passed. The iOS simulator save/reopen and Files checks
  also passed. Milestone closure remains explicitly deferred by the owner.
  There is no CloudKit transport or sync.
- Production file tests inject interruption stages in-process. Real SIGKILL
  history evidence belongs to the spike, whose file procedure the core uses.
  No sudden-power-loss guarantee is established.
- Programmatic marked-text probes are useful integration evidence but do not
  replace interactive testing with physical keyboards and input methods.
- Owner checks on physical iPhone and iPad and longer-note release-build/device
  latency remain open. App Store distribution behavior is not established by
  the local signed Mac build.

The [durability contract](durability-contract.md) and
[execution plan](milestone-1-plan.md) define the continuation boundary.
