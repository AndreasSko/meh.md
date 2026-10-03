# Large-note typing regression

## What happened

Typing in a 500 KB note slowed as the editor gained connected-note and table
support. The measurements below use the same iPhone 18 Pro simulator, iOS 27,
optimized editor build, and live-preview mode. Each run opened a fresh
fictional note in the real `NotebookNoteEditor` and `NoteSession`, committed
edits through Automerge, and saved locally. There was no notebook catalog,
CloudKit connection, prior edit history, or parallel benchmark workload.

| Source state | Typing to idle median | Maximum |
| --- | ---: | ---: |
| Before connected notes (`c633f6e`) | 97.0 ms | 698 ms |
| After connected notes, before tables (`d6f656f`) | 142.4 ms | 1,060 ms |
| Main before the fix (`2091778`) | 144.5 ms | 1,058 ms |
| Initial fix | 82.1 ms | 98 ms |

The final CI wrapper rerun on a fresh, equivalent iPhone simulator measured
14.3 ms median / 21.1 ms maximum for typing in the mixed 50 KB note, and
84.6 ms / 97.3 ms in the standard 500 KB note. Both reports passed the guard,
with zero full parses and 38 incremental parses across the measured edits.

A separate serial pair on one fresh iPad Pro M5 simulator measured 74.5 ms
typing median before the fix and 15.7 ms after it for the mixed 50 KB note.
The old report had 41 full parses and zero incremental parses; the fixed
report had zero full parses and 38 incremental parses and passed the guard.

These figures are one serial run per revision, not device-wide guarantees.
Middle-of-note bold typing medians were 113.2, 168.1, 520.2, and 96.8 ms in
the same order. That operation is especially sensitive to when queued parse
and layout work runs; its single-run differences do not establish that table
support caused the slowdown. Ordinary typing changed little between the
pre-table and main runs, so table support was not the primary regression.

The 500 KB standard fixture has no comments, frontmatter, or horizontal rules,
so its slowdown points to connected-link marker-range work, amplified by the
toolbar querying command availability through the arbitrary-string
`MarkdownSyntaxCache.result(for:)` path. That query could consume a pending
incremental edit and force a full layout. The mixed 50 KB fixture exercises a
separate parser fallback: comments, frontmatter, and horizontal rules could
force a full-document parse during an edit. The fix keeps source text and
selection preservation, NoteSession commits, and saved-text verification
while avoiding full parses for the measured edits.

TestFlight build 27 (version 0.10.5) was published on October 2, 2026 from
the tested, pre-fix revision `2091778`. Later pull-request heads skipped the
publish job. A local App Store Connect check could not authenticate, so no
later distribution is claimed here.

## CI contract

`Editor performance guard` runs on every pull request using the repository's
Xcode 27 runner. It opens the actual native editor in a newly created iPhone
iOS 27 or newer simulator and removes only that simulator afterward. It runs
a 50 KB live-preview note with mixed frontmatter, comments, and horizontal
rules, then a standard 500 KB live-preview note. The runs are serial and use
local storage, without opening a user's notebook or contacting CloudKit.

The regression escaped because the large-note benchmark was opt-in, outside
the regular Swift test run, and had no timing ceiling. CI now runs
deterministic checker tests and a native simulator workflow with timing
gates. The report checker gates these invariants:

- Text, selection, saved text, and final presentation checks all pass.
- Each measured edit performs zero full parses and exactly one incremental
  parse; step totals must match the report aggregates.
- Expected typing, deletion, bulk insertion, and middle-bold samples exist,
  with bounded formatted ranges and current presentation at each idle point.
- Required timings are present and finite. Repeated typing, deletion, and
  middle-bold edit p95 limits are 50 ms synchronous / 100 ms to idle at 50 KB,
  and 150 ms / 250 ms at 500 KB.
- The single bulk-insert sample has separate idle ceilings: 250 ms at 50 KB
  and 1,500 ms at 500 KB. Its synchronous limits remain 50 ms and 150 ms,
  respectively. This is a single-sample ceiling, not a p95 threshold.

The bulk insertion can trigger a multiline viewport stall that is distinct
from repeated character edits. Earlier 500 KB runs measured about 783–810 ms
for the same insertion; one pre-fix run took 1,245 ms. The final 817 ms
sample is below the historical ceiling, but its single sample does not prove
that multiline viewport stalls are fixed. The workload does not establish a
paste or scroll-stall fix, and it does not justify changing production
rendering or save behavior. See the historical profiling notes in
[Editor performance](editor-performance.md).

These generous timing limits are CI machine guardrails, not promises about
physical-device typing or input-to-display latency. The probe does not cover
CloudKit work, all main-actor scheduling patterns, or every possible note.
The guard catches known full-parse and excessive-work regressions, but cannot
prove that all performance regressions are absent. The standalone benchmark
in [Editor performance](editor-performance.md) remains useful for opt-in
profiling; the simulator workflow now applies the timing assertions during
pull requests.

The [serial comparison reports](
benchmarks/editor-typing-regression-2026-10-03.json) record the exact
measurements. The CI workflow uploads JSON reports and logs as artifacts,
including when the native probe fails.

## Validation

The full validation suite passed 936 Swift tests, with six expected skips,
and 44 Python tests. The app also built successfully with the
`meh.md iCloud Dev` scheme and `Debug-iCloud` configuration for iOS Simulator.
The new menu-before-presentation regression test failed on `2091778` with
46 assertions and passed with the fix: the old toolbar path formatted the
whole 80,015-unit note instead of a bounded edit region.

Physical iPhone and iPad typing, user note history, and live CloudKit traffic
have not been validated by these results.
