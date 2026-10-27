# Responsive document History

History opens with the frozen current text while earlier versions load.
Done remains available during loading. Selecting a version reads its text on
the history actor; a later selection cancels and supersedes the earlier one.
Restore is disabled until the selected preview is ready.

## Edit sessions first, details on demand

Long notes made History slow to load. Every saved edit is an Automerge
change, and the index compared the text before and after each one. One
comparison costs about as much as reading the whole note, so a long note
with thousands of changes took minutes on an iPhone and never seemed to
finish.

The index now works in two passes. The first pass reads only each change's
author, time and message, which is cheap, and groups changes into edit
sessions. A session ends when the Automerge actor changes, at a restore,
after a pause longer than three minutes, or when a change's time is earlier
than the one before. The app gets a new actor each time it opens a note, so
reopening a note also starts a session. The pass compares text once per
session, from its first to its last state. That gives the session's size
and skips sessions that left the text unchanged; their changes extend the
previous state, like metadata writes. The rail can show every session after
this pass.

Older app versions saved changes without a time. A real 114 KB diary note
had 6,405 such changes out of 8,821. Their time is the note's modified date
at that change, which costs a read of about 0.4 ms each on a Mac. The
modified date only moves forward, so the pass reads it at both ends of a
run of such changes and splits the run only where the ends lie more than a
pause apart. That note needed 205 reads. Changes without any known time are
a session each.

The second pass loads the steps of one session: the typing between pauses
longer than five seconds. It compares text once per step, the same way.
Single keystrokes are not worth a comparison each: on the diary note one
costs about 20 ms, and a day held over 3,000 of them. History asks for steps
around the selected version: the selected session first, then up to four
sessions on each side. Moving the selection moves this focus and ends the
previous request. Steps load only after the first pass, so the whole rail
is there first.

A loaded session inserts its steps before its stop. The stop keeps its ID
and session size; its own size then compares with the step just before
it. Its date can change when the session ends in metadata-only changes: the
first pass dates the session's last change, the second its last text
change. When no two edits are closer than a step's pause, the index lists
the same states, dates and sizes as the previous per-change index. The one
difference is a session that starts with metadata-only changes: the
previous index counted those toward the earlier state's ID, sessions count
them toward the new session. The app always saves text and metadata
together, so only notes written by other tools can show this.

## Read-only indexing and cache lifetime

`NoteSession` retains one `NoteHistoryReader` for the current change heads.
The reader owns a frozen document. It publishes sessions as a complete
prefix and yields between batches of 32 changes, so previews can
interleave. Each update carries a revision, so History applies the index
stream and the detail stream in order. Current remains a separate
live-position entry.

All subscribers share one producer. Cancelling the last subscriber and the
detail request pauses the index; a later subscriber resumes it. The reader
keeps its builder after the first pass for later step requests. Historical
text uses the indexed frontier, or rebuilds it from the version ID for a
state not loaded yet. Its preview cache keeps at most three texts and at
most 4 MiB; larger selections are returned without caching.

Live changes release the obsolete session cache. Existing browsers keep
their frozen reader until closed. The next opening uses the live revision.
Restoring checks the live heads both before and after
the asynchronous preview read, then appends a marked edit and saves it. The
reader never changes serialized notes or sync state.

## Session measurements

These are optimized Swift tests on one Mac with Automerge 0.7.2, compared
with the previous index in the same process. They are not iPhone timings.
The fixtures below edit every ten seconds, so each edit is a step, and
pause ten minutes after every 40 edits, so they have 15 sessions. The typed
note inserts words at varying places, one character per operation, with 50
changes per session in steps of ten words, like a note written in the app.

| Fixture | Previous index | Sessions | One session's steps |
| --- | ---: | ---: | ---: |
| 121 KB, 600 edits | 5.306 s | 0.188 s | – |
| 500 KB, 600 edits | 21.222 s | 0.722 s | – |
| Typed, 2,000 changes | 3.830 s | 0.285 s | 0.015 s |
| Typed, 6,000 changes | 33.769 s | 2.316 s | 0.042 s |

With one step per edit, loading every session's steps costs about as much
as the previous index: 5.297 s and 21.392 s for the two fixtures. History
never does that; it loads up to nine sessions around the selection.

On the real diary note above, the first pass took 0.43 s and found 5
sessions. Each day's steps, 19 to 36 of them, took up to 0.71 s. Raw data
is in `benchmarks/history-sessions-2026-10-27.json`.

Replaying changes one by one into an empty document does not avoid the
cost: on a typed note with 6,000 changes it took 49.9 s against 56.0 s for
per-change comparisons in the same exploratory run.

## Earlier measurements

The measurements below predate edit sessions. They describe the per-change
index, which the second pass now runs once per step instead. Their fixtures
had no pauses between edits, so their digests differ from the current ones.

The fixture contains 1,800 fictional Unicode Markdown lines, 121,224 UTF-8
bytes and 600 edits. Both runs load the same serialized Automerge bytes.
Measurements use optimized Swift tests on the same Mac and Automerge 0.7.2.
They are individual local samples, not iPhone or iPad timings.

| Core operation | Before | After |
| --- | ---: | ---: |
| First usable historical prefix | 5.310 s | 0.350 s |
| Complete session index | 5.310 s | 5.211 s |
| Reopen unchanged history | 5.312 s | 0.000129 s |
| Three uncached selected previews | 0.1208 s | 0.0164 s |

Full indexing remains approximately the same cost. The improvement removes
the wait for the complete index before opening and avoids rebuilding it on
reopen. Actual app recordings and interaction checks accompany the PR.

The complete version IDs, dates, ordinals and overview stops have the same
digest before and after. Raw measurements and fixture identity are recorded
in `benchmarks/history-performance-2026-10-07.json`.

A second optimized case uses 7,460 Unicode lines, 500,444 UTF-8 bytes and
the same 600 edits. The old algorithm and progressive reader operate on the
same frozen fixture and return identical versions:

| Core operation | Time |
| --- | ---: |
| Old full-index wait | 20.011 s |
| First usable historical prefix | 1.350 s |
| Complete progressive index | 20.363 s |
| Reopen unchanged history | 0.000126 s |
| Three selected previews | 0.0591 s |

These are Mac core timings. This synthetic Markdown body compresses to a
4,406-byte Automerge snapshot; it is a 500 KB text case rather than a
500 KB serialized history case. Raw data and fixture identity are recorded
in `benchmarks/history-performance-500kb-2026-10-07.json`.

Forward replay with Automerge incremental patches was measured and rejected:
it increased total indexing time to about 9.7 seconds on this fixture.
Retaining the original historical comparisons preserves existing semantics
and avoids that regression. No binary format parser or dependency change
was introduced.

## Edit sizes

[Version history](note-history.md) draws each version's edit size. The index
counts it from the body patches it already computes, so no further history
reads are needed. On the same fixture, three optimized runs each took a mean
of 4.991 s for the complete index before and 5.009 s after, within normal
variation; first readiness stayed at 0.33 s. Version IDs, dates, ordinals
and overview stops keep the same digest. Raw data is in
`benchmarks/history-edit-sizes-2026-10-25.json`.

## Swift regression checks

`NoteHistoryTests` and `NoteHistoryReaderTests` load every session's
steps and compare them with the previous index algorithm, including
concurrent branches, metadata, Unicode, restore boundaries and clock skew.
They also cover session and step boundaries, changes without a time,
cancellation, immutable session prefixes, step focus and shared
subscribers. Deterministic counters ensure one decode and one history scan,
that the first pass reads each change once and few modified dates, that
steps load only around the focus, and that cached selections are not read
again.

The editor performance workflow runs the large fixture in Release and checks
first-prefix, full-index, reopen and preview budgets in Swift.
Both the 121 KB and 500 KB cases contain 600 edits. Their first-prefix
ceilings are one and three seconds respectively, with full-index ceilings
of 20 and 60 seconds. Both retain the same-process regression factor,
50 ms reopen ceiling and 250 ms preview ceiling. Fixture hashes, text sizes
and version digests prevent these checks from silently using smaller data.
A same-process comparison with the old algorithm also guards the session
index and full details against regressions across runner speeds. The typed
benchmark runs with 300 changes by default; set
`MEH_HISTORY_TYPED_CHANGES` for larger runs and
`MEH_HISTORY_TYPED_MINIMUM_SPEEDUP` to require a speedup over the previous
index. The native
editor regression workflow also runs the History UI tests, including a large
fixture, rapid selection changes, reopening and returning to writing.

To repeat the optimized history checks:

```sh
MEH_HISTORY_BENCHMARK_EDITS=600 MEH_HISTORY_BENCHMARK_LINES=1800 \
MEH_HISTORY_INDEX_BUDGET_SECONDS=20 \
MEH_HISTORY_INDEX_REGRESSION_FACTOR=1.35 \
MEH_HISTORY_FIRST_READY_BUDGET_SECONDS=1 \
MEH_HISTORY_REOPEN_BUDGET_SECONDS=0.05 \
MEH_HISTORY_PREVIEW_BUDGET_SECONDS=0.25 \
swift test -c release \
  --filter 'NoteHistory(Tests|ReaderTests|PerformanceTests)'

MEH_HISTORY_TYPED_CHANGES=6000 swift test -c release \
  --filter testTypedNoteHistoryBenchmark
```

For the 500 KB case, use `MEH_HISTORY_BENCHMARK_LINES=7460`,
`MEH_HISTORY_INDEX_BUDGET_SECONDS=60` and
`MEH_HISTORY_FIRST_READY_BUDGET_SECONDS=3` with the same other settings.

UI fixtures are compiled only in Debug. They require explicit isolated
preview mode and a valid run name in iCloud Dev; they never seed the cloud
notebook and refuse to overwrite an existing catalog.
