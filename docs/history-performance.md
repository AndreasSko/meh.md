# Responsive document History

History opens with the frozen current text while earlier versions load.
Done remains available during loading. Selecting a version reads its text on
the history actor; a later selection cancels and supersedes the earlier one.
Restore is disabled until the selected preview is ready.

## Read-only indexing and cache lifetime

`NoteSession` retains one `NoteHistoryReader` for the current change heads.
The reader owns a frozen document. It publishes finalized causal prefixes in
batches of 32 changes and yields between batches so previews can interleave.
Metadata-only changes extend the unresolved candidate; the next body change
fixes its frontier and typing-group boundary before publication. Current
remains a separate live-position entry as the historical prefix grows.

All subscribers share one producer. Cancelling the last subscriber pauses
the index; a later subscriber resumes it. The reader releases its builder on
completion. Historical text uses the indexed frontier without scanning the
complete history again. Its preview cache keeps at most three texts and at
most 4 MiB; larger selections are returned without caching.

Live changes release the obsolete session cache. Existing browsers keep
their frozen reader until closed. The next opening uses the live revision.
Restoring checks the live heads both before and after
the asynchronous preview read, then appends a marked edit and saves it. The
reader never changes serialized notes or sync state.

## Matched local measurements

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

## Swift regression checks

`NoteHistoryTests` and `NoteHistoryReaderTests` compare with the previous
index algorithm, including concurrent branches, metadata, Unicode, typing
groups, restore boundaries, cancellation, immutable prefixes and shared
subscribers. Deterministic counters ensure one decode and one history scan,
cache reuse on reopen, and no repeated preview reads for cached selections.

The editor performance workflow runs the large fixture in Release and checks
first-prefix, full-index, reopen and preview budgets in Swift.
Both the 121 KB and 500 KB cases contain 600 edits. Their first-prefix
ceilings are one and three seconds respectively, with full-index ceilings
of 20 and 60 seconds. Both retain the same-process regression factor,
50 ms reopen ceiling and 250 ms preview ceiling. Fixture hashes, text sizes
and version digests prevent these checks from silently using smaller data.
A same-process comparison with the old algorithm also guards full indexing
against regressions across runner speeds. The native
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
```

For the 500 KB case, use `MEH_HISTORY_BENCHMARK_LINES=7460`,
`MEH_HISTORY_INDEX_BUDGET_SECONDS=60` and
`MEH_HISTORY_FIRST_READY_BUDGET_SECONDS=3` with the same other settings.

UI fixtures are compiled only in Debug. They require explicit isolated
preview mode and a valid run name in iCloud Dev; they never seed the cloud
notebook and refuse to overwrite an existing catalog.
