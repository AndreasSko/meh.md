# Automerge local spike

Date: 2026-09-12
Status: local spike complete, including real native adapter validation.

## Outcome

Automerge is suitable for the local document core. The tested package can
preserve literal Markdown, stable note identity, and merge history in one
serialized file. Independent replicas converge after separate and
same-position edits, including after both replicas are saved and reloaded.

Use Automerge's default Unicode-scalar text indexing. Convert the UTF-16
`NSRange` values used by AppKit and UIKit at the native adapter boundary. The
spike verifies conversion in both directions and rejects a range that splits a
surrogate pair.

Do not introduce SQLite, a custom journal, or a fork of Automerge. Continue
with direct serialized files, one serialized writer, and a previous known-good
file.

## Tested dependency

- Package: `https://github.com/automerge/automerge-swift.git`
- Version: `0.7.2`, pinned exactly in `Package.resolved`
- Revision: `aa45d17ac92cef2b8ded63b47e65a28dc85e3418`
- Product: `Automerge`
- Tested toolchain: Xcode 27.0, Apple Swift 6.4

The package supports macOS 10.15 and iOS 13 or newer. The spike declares
macOS 15 and iOS 18 and also builds against the project's current iOS 27 SDK.

## Document shape and editing

The spike document contains:

- `noteID`: a UUID string that remains stable across save, reload, and merge;
- `schemaVersion`: unsigned integer `1`;
- `text`: an Automerge `Text` object containing literal Markdown.

The tests cover headings and code markers, multiline text, emoji with
modifiers, a family emoji, precomposed accents, and a decomposed accent.
Loading rejects a missing, non-integer, or unsupported schema version.
Native UTF-16 ranges are converted to Unicode-scalar offsets before calling
`spliceText`. A reverse conversion is available for future Automerge patches.

The existing editor currently emits whole-text snapshots. `updateText` accepts
those snapshots, including the strings produced by native undo and redo.
The original bare-text-view probe manually called `didChangeText` after undo;
that did not establish automatic adapter behavior. A follow-up probe mounts
the actual `MarkdownEditor` in `NSHostingView` with an Automerge binding.
It found undo and redo changed visible text without a delegate callback or
`NSText.didChangeNotification`. The owner approved a scoped UndoManager
completion observer, now implemented in the macOS adapter. The mounted tests
pass automatically on macOS and an iOS simulator, including marked-text
completion and exact Unicode bytes. UIKit needed no undo workaround. The
obsolete manual-callback probe was removed.

Automerge batches pending operations into changes. Its history is suitable for
merging and persistence, but it is not the editor's undo stack. Native text
views continue to own user undo and redo.

## Serialization and replicas

`Document.save()` followed by `Document(data:)` preserved the note ID, exact
UTF-8 text bytes, heads, and history. The reloaded document accepted further
edits whose history still contained the saved heads. A loaded document
receives a new actor ID. Forked and loaded replicas also receive distinct actor
IDs, avoiding concurrent writes from the same actor.

Tests made separate edits at the beginning and end of a shared text, merged in
both directions, and observed identical content. Repeating a merge neither
duplicated content nor added history. Concurrent inserts at the same position
were both retained in a deterministic order shared by both replicas. The
specific order depends on actor IDs and must not be presented as user-defined.

An initially attractive UTF-16 document mode was rejected. It matches native
editor ranges before saving, but Automerge Swift 0.7.2's `Document(data:)`
loads using the platform default Unicode-scalar mode. The serialized format
does not store this API setting, and the Swift wrapper does not expose the
Rust load option that selects it. Using Unicode-scalar indexing consistently
avoids maintaining a custom Automerge binary framework.

## Safe file procedure

The spike uses `note.automerge` as the current file and
`note.previous.automerge` as the previous known-good file. The writer performs
these operations on one serialized execution path:

1. Parse the incoming bytes as an Automerge note.
2. Write a uniquely named temporary file in the destination directory.
3. Flush the temporary file with `fsync`.
4. If a current file exists, parse it, verify the same note ID, and require
   its heads to exist in the incoming document's history.
5. Write and flush the current bytes to another temporary file.
6. Atomically rename that file over the previous file.
7. Atomically rename the new file over the current file.
8. Flush the containing directory with `fsync`.

An invalid incoming file, invalid current file, different note ID, or history
without the current heads stops the write without replacing the current or
previous file. Recovery reports absent, corrupt, unreadable, and unsupported
states separately. A valid previous file is returned as an explicit candidate
after a corrupt or unreadable current file. An unsupported current schema is a
compatibility error and does not offer an older previous file. The spike does
not create a new document or identity when existing files are unreadable.

Injected errors and separate-process `SIGKILL` checks produced these results:

| Interruption point | Current file | Previous file |
| --- | --- | --- |
| After new temporary file flush | Old document | Absent |
| After previous-file rename | Old document | Old document |
| After current-file rename | New document | Old document |
| After directory flush | New document | Old document |

A process killed after the current-file rename may have committed the new
document even though the caller never received success. On reopening, the app
must inspect the current document rather than assume the last acknowledged
snapshot is still current. Identify snapshots by their Automerge heads.

For every interruption point, the process test reloads the recovered document,
edits and saves it in a new writer process, verifies that history and heads
advance, and merges an offline fork made before the interruption. This checks
CRDT continuity across a real kill and reopen instead of relying on the UUID.

## Size and timing observation

One release-independent debug test used 54,780 UTF-8 source bytes and 250
appended edits split across 25 committed autosaves. On this development Mac,
editing took about 0.65 seconds in total. Serialization took about 0.029
seconds in total, and the 25 full storage writes took about 0.81 seconds in
total. Each storage write included the current and previous temporary-file
writes and flushes, replacements, and directory flush. The final serialized
document was 6,246 bytes. These are one debug run's observations, not product
guarantees or tail-latency measurements.

Full-document saving is a reasonable starting point. Measure again through
the production session and on physical devices before adding incremental save
or compaction behavior.

## Verification commands

Run the macOS tests:

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/meh-md-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/meh-md-swiftpm-cache \
  swift test --disable-sandbox \
  --package-path Spikes/AutomergeSpike
```

Run real process-interruption checks:

```sh
Spikes/AutomergeSpike/scripts/check_interrupted_writes.sh
```

Compile the spike and Automerge binary framework for iOS:

```sh
cd Spikes/AutomergeSpike
xcodebuild -quiet -scheme AutomergeSpike \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/meh-md-automerge-ios \
  CODE_SIGNING_ALLOWED=NO build
```

Results on 2026-09-12:

- 20 macOS spike tests passed before removal of the manual-callback probe;
  the remaining 19 test the document and file path.
- Three replacement tests against the actual editor passed on macOS and an
  iPhone 17 iOS 27 simulator, without manual delegate calls.
- Four separate writer processes were killed at distinct save boundaries. All
  expected file states were recovered, edited after reopen, and merged with an
  earlier offline fork while preserving history.
- The generic iOS build succeeded.

## Limits and next decision

The spike does not establish CloudKit behavior, cross-device delivery,
external Markdown-copy safety, release-build or physical-device latency,
concurrent writer behavior, or sudden-power-loss behavior on physical devices.
The file procedure requires a single writer. The current and previous files
are separate replacements and do not form one atomic transaction. The app's
directory is assumed to be reachable; parent-directory lookup failures are not
separately classified by this bounded spike.

The [durability contract](durability-contract.md) now defines snapshot
acknowledgment using Automerge heads, fallback reporting, and retention.
The file-history and native adapter follow-ups are complete. The production
core and app integration now implement the first local save/reopen slice.
