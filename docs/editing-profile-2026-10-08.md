# Editing profile: 8 October 2026

Typing in a large Markdown note now does less work on the main thread. The
changes preserve immediate formatting, literal Markdown, native undo, and
stale-revision merging. They address the bold-editing CI regression in #204.
The broader physical-iPad acceptance in #37 remains separate.

## Workload and method

The real `NotebookView`, native editor, `NoteSession`, local catalog, and
ordinary autosave run in the isolated Editor Quote Check application. No
CloudKit connection or personal notebook is opened. The fictional 500,108-byte
fixture includes headings, links, emphasis, highlight, strikethrough, lists,
quotes, code fences, and Unicode. Smaller mixed-context and nearby-table cases
remain in CI.

Measurements use iPhone 18 Pro / iOS 27.0 (24A434), on an Apple M3 Max host
with macOS 27.0.1. All binaries use `-O -g` and iCloud Dev compilation
conditions. They were built before measurement. Two independent launches per
variant ran in the order baseline, native hint, selection, selection, native
hint,
baseline. The note starts fresh each time; it has no prior edit history.

Each launch types 21 characters, deletes six, inserts one paragraph, then
opens, types, and closes bold in the middle of the note. Source, caret,
full-parser equivalence, current presentation at idle, and saved-file fidelity
are checked. The ordinary pause between actions is outside the measurement.

The synchronous metric covers the native edit call. The idle metric extends
through the next main-run-loop `beforeWaiting` observation. It includes
formatting and other main-thread work; it is not physical input-to-display
latency. Screen recordings show the actual native workload, with programmatic
`insertText` and `deleteBackward`, rather than physical keyboard input.
Recordings are attached to the PR, not committed here.

[Raw measurements](benchmarks/editing-performance-2026-10-08.json)
retain both launches of each variant, including outliers. The initial
single-run measurements, a run overlapping compilation, and profiler runs do
not contribute to the comparison table.

## Results by commit

Values are milliseconds, calculated as the median of the two run medians.

| Operation | Baseline | Native hint | Selection snapshot |
| --- | ---: | ---: | ---: |
| Ordinary typing, synchronous | 24.00 | 23.85 | 22.73 |
| Ordinary typing, until idle | 101.57 | 100.93 | 69.26 |
| Bold typing, synchronous | 66.63 | 38.02 | 38.26 |
| Bold typing, until idle | 152.02 | 120.87 | 91.74 |
| Paragraph insertion, until idle | 114.55 | 100.71 | 72.92 |

- `61d7c40`: comparable benchmark builds and parser variance calibration;
  production editor behavior matches main `1278eaa`.
- `2df8574`: captures native character intent before TextKit attribute fixing.
  Bold synchronous typing improved 43% relative to the baseline.
- `9d335fa`: reuses the literal native snapshot for selection reporting and
  compares literal UTF-8 at the completion boundary. Ordinary typing until
  idle improved 31% relative to the preceding commit.

Combined, bold typing until idle improved 40%. This is a matched local
simulator result. It is not a percentage claim about physical devices or
GitHub's hosted runner.

## Profiler attribution

Two focused Instruments Time Profiler recordings bracketed the same 38 edit
intervals with the existing `Large note edit` signposts. CPU analysis excludes
full-parser correctness checks between edits. Samples are at 1 ms intervals;
counts below are inclusive and must not be added together.

Before the changes, 159 of 403 main-thread samples during synchronous bold
characters included `NoteDocument.applyEditorText` and the whole-text path.
109 included the Automerge `update_text` entry point. Ordinary edits already
used the validated native-delta path. TextKit widened the character range
while fixing attributes, causing middle insertions to lose their pure-edit
hint. Capturing the range before fixing preserves the existing validated
splice without deleting and reinserting unchanged paragraph text.

After both changes, none of 244 synchronous bold samples included the
whole-text path. The validated splice appeared instead. The core still checks
literal reconstructed text and the displayed revision before accepting a
hint. Mixed replacements and stale revisions retain their existing fallback.

Before, the selection callback occurred in 718 of 2,286 ordinary edit-to-idle
main-thread samples, dominated by Unicode normalization in whole-note
`String` equality. After, it appeared in 50 of 1,622 samples. Selection reports
now reuse the immutable native snapshot already used by committing and
presentation, and completion checks compare literal bytes.

The remaining profile includes native TextKit range updates, snapshot copying,
Live Preview concealment, and drawing. These were measured, but this PR does
not claim to eliminate all document-wide work. The optimized trace still has
220 ordinary-edit samples in Live Preview range preparation. Serialization
was only a few samples in the completed baseline trace; the earlier transient
one-second outlier is not established as a save bottleneck. No save or
rendering work was moved to a background queue.

A first broad, host-wide trace hit simulator symbol-mapping trouble and did
not finish cleanly. It is excluded. The successful traces attach to the iOS
simulator device and only the disposable benchmark process.

## Rendering and validation follow-up

The first valid hosted reports showed long pauses with main-thread CPU close
to wall time. A local device-attached profile reproduced those pauses. They
were real rendering work, so the absolute budgets were kept unchanged.

The additional changes are split into three production commits:

- `dcd18d1` indexes code-block starts and caches dynamic rendering dictionaries
  for each installed syntax result. Selection-only presentations reuse the
  index; edits and syntax installation invalidate it. Three balanced launches
  reduced ordinary idle p95 from 221.49 to 182.63 ms, a 17.5% improvement.
- `498da5d` validates the exact UTF-16 prefix, replacement, and suffix without
  constructing a second whole Foundation string. Length-changing validated
  edits skip the redundant no-op comparison. The initial three-run aggregate
  reduced ordinary synchronous median from 23.78 to 21.41 ms, about 10%.
- `3698141` paints final disjoint attribute intervals instead of resetting a
  fragment and repeatedly overwriting it. Setter dictionaries still replace
  earlier dictionaries; uncovered intervals retain add-only foreground
  behavior. Three later paired launches reduced bold-open synchronous median
  from 64.59 to 37.86 ms, and idle median from 125.01 to 95.83 ms.

The last comparison does not show a universal latency gain. Ordinary typing
medians were 65.18 and 65.84 ms until idle; the new stage still had a 351.59 ms
ordinary outlier and a 346.48 ms bulk-insert outlier. All six reports passed
fidelity and structural validation; this statement does not imply CI budget
acceptance. The initial validation-stage aggregate is supplemental: its first
raw report was overwritten during the later repeat. The complete later paired
reports, initial rendering reports, launch logs, and retained aggregates are
in [the follow-up evidence](benchmarks/rendering-performance-2026-10-08.json).

A follow-up Time Profiler trace contains all 38 edit intervals. Rendering
callback samples across edits fell from 886 before the index to 533 with the
index and validation changes, then 4 with disjoint commands. Paragraph-based
classification fell from 287 to zero. TextKit run-storage samples fell from
303 to 277 to 20. Counts are inclusive and overlap.

One preceding profile had a bulk-insert interval of 731.93 ms wall time and
729.66 ms main-thread CPU; 520 samples were in rendering callbacks. The final
profile measured bulk insertion at 91.18 ms wall and 91.13 ms CPU. Its longest
interval was initial typing at 231.37 ms. These are diagnostic traces from
separate launches, not independent latency estimates. The earlier baseline's
largest rendering burst occurred during typing rather than bulk insertion.

The 47 selected native iOS tests passed after the final changes. They include
full attribute equivalence against the legacy implementation for both base
modes, nested and adjacent spans, concealment, retained unrelated attributes,
and dynamic colors. Nine focused core edit tests also passed. A broader
245-case package-native run had five assertions fail in three existing
navigation/viewport tests and one expected skip. Hosted CI on `d7bd3e3`
compared 240 baseline and 245 current methods: the same three failing methods
and one skip, with all five new invariants passing. The 47 selected native
tests and 11 keyboard UI tests passed. No new failing or skipped methods
were found. The full hosted Debug Swift suite passed 1,034 tests with nine
expected skips and zero failures; both release builds passed.

Main later advanced with Mac formatting PR #211. The production commits
rebased cleanly; its changes affect Mac controls and preserve the measured
iOS editor implementation. The new patch version is 0.11.11. Before/after
recordings use the same disposable iPhone simulator and fictional note. All
local UI automation ended before the user's one-hour window expired.

## Regression protection and validation

See [editor performance](editor-performance.md) for CI sampling, the frozen
reference, and noise allowances. The reference is the optimized production
commit `3698141`; the historical slow baseline remains unchanged. Every paired
run retains absolute and fidelity checks. Relative comparison uses three
independent launches in alternating order, including bold edits.

Local release tests passed 1,027 tests with 12 expected environment or opt-in
skips and zero failures. Focused native edit, selection, and remote-update
coverage passed 30 tests, including undo/redo and marked-text stale merging.
The new attribute-fixing test deliberately widens the did-process range and
checks that exact Unicode insertion and deletion hints survive. The selection
test checks literal current content and one snapshot per character revision.
The iOS regression workflow explicitly runs the native edit, selection, and
rendering invariant classes and requires all 47 selected cases to pass.
Its additional full-suite comparison uses pinned main `64a7267`, separate
builds, and a task-owned iPhone 18 Pro simulator. It rejects missing exports,
new failures or skips, and incomplete method inventories. Existing baseline
failures remain visible in the published result bundles.

Main advanced with formatting PR #203 during profiling.
The production commits rebased cleanly; their original measured revisions
remain in the table. The frozen CI reference includes the updated formatting
controls. Final simulator UI, exact-head CI, and CodeRabbit results are
recorded in the PR. Physical devices were unavailable for this run. Live
CloudKit and physical
input/display timing are outside the evidence collected here.

## Remaining hosted cold-edit spikes

The hosted `d7bd3e3` performance run passed History, catalog, Unicode parsing,
and the two 50 KB controls, but the 500 KB native guard still failed. Current
run one reached 623.60 ms wall / 614.76 ms CPU on the second typed character.
Current run three reached 531.49 ms wall / 505.66 ms CPU there, and the first
middle-paragraph bold marker took 181.51 ms wall / 181.33 ms CPU. The frozen
optimized reference showed similar early-typing and cold-bold spikes.

These are real main-thread costs, not established scheduling noise. Later
ordinary typing stayed below 203 ms in all three current launches. The
post-failure diagnostic failed during simulator installation with a dead
CoreSimulator server and produced no trace. A diagnostic-only dispatch now
uses a fresh hosted machine, prebuilds the same frozen Dev source, and retains
unscored raw timing, CPU trace, logs, and symbols. It cannot waive a scored
performance failure. No local UI automation is needed for that dispatch.

[Hosted evidence](benchmarks/editor-ci-performance-2026-10-08.json) records the
verified workload identities, wall/CPU measurements, and native parity result.
The user accepted bounded cache warm-up and prioritized ongoing editing.
Cold-only optimization was stopped; the diagnostic-only run was cancelled
while queued. No speculative viewport reuse change was adopted.

CI now separates the first three ordinary cold inputs and the first
middle-note bold marker from warm editing. Later ordinary inputs tighten
from 500 to 300 ms; warm medians and p95 retain historical improvement and
optimized-reference guards. All raw cold inputs remain visible, with
individual, cumulative, and paired limits. See the phase budgets in
[editor performance](editor-performance.md). Final hosted validation of
this calibrated protocol is required before merging.
