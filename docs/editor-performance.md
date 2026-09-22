# Editor performance

This change follows the writing-tools work in PR #36 and addresses issue
#37. It targets Markdown parsing and native TextKit rendering, independently
of notebook replication or iCloud storage.

## Measured bottlenecks and changes

The parser previously searched every code range for each source position,
filtered every font span at every style boundary, and scanned all lines for
each fenced block. Sorted range lookup and ordered sweeps now avoid that
repeated work without changing the supported Markdown syntax.

TextKit previously rebuilt rendering decisions and compared full note strings
for individual visible fragments. A prepared presentation snapshot now holds
syntax, hidden-marker ranges, and the decoration plan. An interval index
selects only spans intersecting the fragment, including enclosing spans that
start before it. Character edits invalidate the snapshot immediately. Normal
presentation-only attribute changes do not trigger another Markdown parse.

Ordinary edits reuse cached syntax outside a bounded region and rebuild
layout attributes only for affected paragraphs. Full parsing remains the
fallback when cached edit context is unavailable or invalid, or when finding
a safe restart boundary would require parsing more than 65,536 UTF-16 units
(for example, after opening a long code fence). Initial presentation, full
parse fallbacks, and font changes can still require document-wide layout
attributes. Broader TextKit viewport and rendering costs remain separate
optimization work.

## Reproduce

Use an existing iOS 27 or newer simulator. The runner reuses the existing
Editor Quote Check test application and generates a fictional note in memory.
It never opens the notebook, private notes, or iCloud. The chosen test app is
replaced on the selected simulator; no new app identity is introduced.

```sh
scripts/run_editor_performance_check.sh SIMULATOR_UDID \
  2ac68f4 livePreview 150 /tmp/editor-before.json presentation
scripts/run_editor_performance_check.sh SIMULATOR_UDID \
  working-tree livePreview 150 /tmp/editor-after.json presentation
```

Repeat with `source` instead of `livePreview`. The optional block count ranges
from 1 to 500; 150 blocks produce a 38,264 UTF-16-unit note with headings,
links, emphasis, highlights, strikethrough, nested lists/quotes, and code.
A Git reference compiles the editor sources from that revision together with
the current profiling harness, without changing the checkout or making a
worktree. Run baseline and candidate sequentially on the same idle host.

The runner uses Swift optimization (`-O`), waits one second for the initial
keyboard transition, and samples seven edits and repeated shallow/deep scroll
positions. It records all timings and checks exact text and caret preservation.
Scroll timings include synchronous layout and Core Animation flush work;
they are not frame rates or a physical-device smoothness measurement.
The totals include benchmark timer bookkeeping. Compare like-for-like on the
same host; the sample count is intended for directional local comparisons,
not CI timing thresholds.

## Results and acceptance

Measurements were collected on an Apple M3 Max host running macOS 27.0 with
iOS 27.0 simulators. The baseline is the writing-tools commit `2ac68f4`.
Times below are medians in milliseconds, with baseline followed by candidate.

| Operation | iPad Live | iPad Source | iPhone Live |
| --- | --- | --- | --- |
| Parse | 217.7 → 4.3 | 218.2 → 4.2 | 219.4 → 4.3 |
| Initial presentation | 638.9 → 63.2 | 579.4 → 46.0 | 582.0 → 58.8 |
| Typing and refresh | 280.9 → 40.4 | 270.0 → 32.5 | 271.7 → 39.4 |
| Unchanged refresh | 63.2 → 36.5 | 54.6 → 29.5 | 54.8 → 35.4 |
| Shallow scroll/layout | 105.4 → 8.7 | 99.9 → 7.6 | 80.8 → 9.5 |
| Deep scroll/layout | 108.4 → 10.9 | 102.9 → 9.8 | 83.0 → 11.5 |

Physical-device scrolling acceptance remains an owner check. The known
German physical-keyboard tilde composition behavior is unchanged. No parser,
font, marker, or keyboard behavior is intentionally changed by this PR.

Validation: the complete deterministic validation run passed 390 Swift tests
(286 core, 99 native editor, and 5 app-model tests) with zero failures and one
expected headless caret-host skip, plus 16 Python tests. The actual Mac caret
harness passed separately. The final native editor rerun and Mac build passed.
Three targeted iPad UI tests and three iPhone UI tests passed for formatting,
mode changes, source preservation, quote/bullet rendering, and continued
editing. The iPhone set also checked keyboard dismissal. Captured iPad
screenshots were inspected for marker and quote alignment.

## Note-session typing and save batching

The editor now passes a small, session-scoped revision token containing the
current Automerge heads. A matching revision applies directly to the live
in-memory document. A stale revision forks that document at the displayed
heads, applies the native edit, and merges the fork back. This retains remote
changes received during composition without a full-history ancestry scan for
ordinary typing. General remote-document validation is unchanged.

Full snapshots are cached by revision and created on demand. Disk saves start
at one second idle or at most five seconds into continuous typing. A single
writer coalesces edits made during a save; flush, retry, and first creation
bypass the timer. See the updated durability contract for the crash-loss
window and lifecycle behavior.

A bounded synthetic debug check with roughly 12 KB of text and 100 prior edits
completed 20 session commits in about 30 ms total on the development Mac.
This excludes rendering, disk completion, network work, and real-library
history; it is not a frame-time or end-to-end acceptance result. Reproduce:

```sh
MEH_MEASURE_EDITOR_COMMITS=1 swift test \
  --filter NoteEditorCommitTests
```

Deterministic coverage includes delayed saves, the maximum delay, slow and
failed writes, deletion cancellation, stale local/remote revisions, malformed
and foreign editor tokens, persistence, and convergence. Full owner profiling
remains a separate acceptance check. Moving sync processing off the UI thread
is tracked separately in GitHub issue #52.

## Large-note typing baseline

The `large-note` scenario hosts the actual `NotebookNoteEditor`, including its
SwiftUI binding, native coordinator, `NoteSession`, Automerge commits, and
`NoteFileStorage`. It uses a fresh, disposable document in the existing probe
app. It does not open the user's notebook or connect to CloudKit.

```sh
# Default: 500 KB, live preview, current checkout.
scripts/run_editor_performance_check.sh SIMULATOR_UDID

scripts/run_editor_performance_check.sh SIMULATOR_UDID \
  working-tree livePreview 250 /tmp/large-note-250.json large-note
scripts/run_editor_performance_check.sh SIMULATOR_UDID \
  working-tree livePreview 500 /tmp/large-note-500.json large-note
```

For this scenario the size argument is decimal UTF-8 KB, rounded up to a whole
fixture block, rather than the presentation probe's block count. The default
is 500 KB. Sizes from 1 to 2,000 KB are supported so smaller control runs are
possible. Only `working-tree` is supported: run from the desired checkout to
keep core and editor sources consistent. Both are compiled with optimization.

The fixture contains fictional paragraphs, headings, links, lists, quotes,
code fences, and Unicode. The runner exports the exact Markdown alongside the
JSON report as `<output-stem>-fixture.md`. No large fixture is checked in.

After opening the note and settling the keyboard, the probe types 21
characters at the end, deletes six, and inserts a paragraph in one native
insertion call. The latter simulates pasted text but does not use the clipboard
or measure paste UI. It then moves to the middle of the note and types the
opening markers, six letters, and closing markers of bold separately. Each
middle edit also checks its presentation against a fresh full parse. Each
edit checks literal native/session text and caret
position outside the measured region. Finally, the probe waits for normal
autosave and reloads the saved file to check exact text preservation. Any
failure exits the runner unsuccessfully; there is no machine-dependent timing
assertion and this opt-in benchmark is not part of the regular test suite.

The JSON contains every sample and action, source revision, dirty-checkout
status, simulator identity, and fixture byte count. Interpret the timings as:

- `*_synchronous_ms`: the native edit call, including synchronous delegates.
- `*_to_idle_ms`: from edit start to the next main-run-loop `beforeWaiting`
  observation, including deferred work that runs before that point. This is a
  responsiveness proxy, not input-to-display latency or a Hangs measurement.
- `autosave_wait_including_debounce_ms`: remaining wait after the final edit;
  it includes debounce and excludes saves already completed during typing.
  It must not be interpreted as serialization or disk-write duration.

There is a 50 ms pause between actions, outside the timings. The probe does
not force a presentation refresh per edit; it exercises normal scheduling.
Instruments Points of Interest intervals named `Large note edit` bracket the
edit-to-idle measurements. An attached CPU profile can further separate
parsing, comparisons, commits, and save work without production
instrumentation.

Baseline on 2026-09-21: production sources at `3285bc6`, iPhone 17 simulator,
iOS 27.0 on an Apple silicon macOS 27.0 host, Release core and `-O` editor.
These are synthetic simulator results, not physical-iPad acceptance numbers.

| Fixture | Typing call median | Typing to idle median | To idle maximum |
| --- | ---: | ---: | ---: |
| 50,288 bytes, control | 13.6 ms | 51.2 ms | 74.3 ms |
| 250,208 bytes, run 1 | 50.2 ms | 237.9 ms | 316.5 ms |
| 250,208 bytes, run 2 | 52.3 ms | 236.9 ms | 297.4 ms |
| 500,108 bytes | 96.5 ms | 514.1 ms | 637.8 ms |

Each row has 21 single-character edits. Text, selection, and saved-file checks
passed in all four runs. No historical-edit fixture or sync traffic was
needed to reproduce slow edit processing. Doubling the note approximately
doubled the measured typing cost. This establishes a repeatable baseline; it
does not independently attribute that cost to individual functions. The
250 KB paragraph-insertion samples varied from 487 to 550 ms to idle, so use
the repeated typing samples as the primary comparison after optimizations.

### First optimization: avoid redundant text traversal

The large-note scenario is now the runner's default, at 500 KB. The original
presentation-only scenario remains available with an explicit `presentation`
argument.

On both UIKit and AppKit, a successful revision-aware commit now acknowledges
the backing model's update without writing the same text through the binding
again. Representable updates with the already-displayed revision skip the
whole-buffer comparison, after checking composition, pending edits, and font
or presentation-mode changes. New revisions still take the existing text
comparison/replacement path, and binding-only editors retain their setter.

Native edit snapshots also call `makeContiguousUTF8()` once before comparison
and commit. This avoids repeatedly traversing a bridged NSString's UTF-16
storage through its UTF-8 view. It preserves literal Unicode bytes, including
decomposed text; it does not perform Unicode normalization. Bridged strings
may incur a transient UTF-8 copy in exchange for less traversal work.

Same 500,108-byte fixture, simulator, and optimized build settings as above;
benchmarks ran separately from tests/builds that could compete for CPU:

| Version | Typing call median | Typing to idle median | To idle maximum |
| --- | ---: | ---: | ---: |
| Fresh baseline | 96.1 ms | 515.2 ms | 627.6 ms |
| Optimized, run 1 | 48.5 ms | 453.9 ms | 583.9 ms |
| Optimized, run 2 | 48.3 ms | 453.9 ms | 602.2 ms |

The repeated result is approximately 50% less synchronous edit time and 12%
less time to the next idle point. Removing the duplicate binding write and
using the revision fast path alone measured 95.0 ms / 500.6 ms; making the
snapshot UTF-8 contiguous accounts for most of the synchronous improvement.
Whole-document parsing, styling, and Automerge updates are unchanged, so
substantial latency remains. All baseline/candidate runs preserved literal
text, selection, and autosaved content.

Focused regressions cover commit acknowledgement without a second binding
write, undo/redo, skipping text reads for acknowledged revisions, and rejecting
stale parent updates while retaining the correct next-edit revision. Existing
tests also cover marked-text/remote merges, same-text new revisions, failed
commits, literal decomposed Unicode, formatting commands, and caret positions.
The new redundant-work assertions failed before the production change and
passed afterward.

Validation: 41 focused Swift tests passed, with the existing headless native
insertion-indicator test skipped. Three iPhone simulator UI tests passed for
typing after bold/strikethrough, list/quote source preservation, and writing
controls with Source/Live Preview switching. Both optimized 500 KB runs passed
the exact-text, caret, and disk round-trip checks. Physical-device performance
and real keyboard IME interaction remain unverified by this change.

### Incremental parsing and layout

Ordinary edits reuse cached syntax outside the affected LF-delimited line.
Native UTF-16 edit ranges determine which line is reparsed; later syntax ranges
are shifted. Attribute rebuilding and rendering invalidation cover only the
affected paragraph range. Existing offscreen attributes preserve layout
geometry.

Newline edits, lines containing emphasis/code markers, and existing spans that
cross the edited line retain a synchronous full-parse fallback. This
conservative
first pass does not defer formatting. Caret movement updates changed
concealment;
font changes and external attribute changes invalidate the complete layout.
Syntax metadata arrays and preview indexes still involve document-wide work,
as does the Automerge commit path.

A 500 KB simulator comparison with background parsing disabled measured:

| Measurement | Original | Text + incremental optimizations |
| --- | ---: | ---: |
| Typing call median | 96.06 ms | 48.79 ms |
| Typing to idle median | 515.15 ms | 80.46 ms |
| Typing to idle maximum | 627.61 ms | 203.35 ms |

The median idle interval improved about 84%. All 21 typed characters and six
backspaces used incremental parsing. Each attribute pass covered only 15-35
UTF-16 units out of 491,603 in the initial note. Presentation was current at
every measured idle point, and text, caret, final syntax, and autosave checks
passed. These timings are single-run simulator measurements, not CPU
percentages
or physical-device results.

The multiline insertion still needed a full parse: 1,245 ms to idle, with a
maximum main-actor scheduling delay of 662 ms. This remains an unresolved cost.
The synchronous edit call also remains about 49 ms. Range-based Automerge edits
and broader incremental parsing are future work.

Focused regressions compare incremental syntax and native attributes against a
fresh full parse/refresh, including Unicode replacement, marker deletion,
multiline fallback, and remote-edit behavior. The background parsing experiment
is maintained separately; it is not enabled in this change.

The comparison report is `/tmp/meh-incremental-synchronous-corrected.json`.
Temporary reports and fixtures are not committed to the repository.

After splitting the background experiment into its own PR, the synchronous
branch passed 81 focused tests with one known headless insertion-indicator test
skipped. A generic physical-iOS Debug build passed with signing disabled. This
verifies compilation, not an installed iPad run; hardware testing remains open.

## Revision cache and batched edits

The native editor now shares one immutable contiguous text snapshot between
committing and presentation. The observed text storage's character revision
identifies cached syntax without rescanning the text. Attribute-only changes
retain the snapshot; character edits and storage replacement invalidate it.
Arbitrary string callers still use exact text comparison, and cannot lend
native revision identity to unrelated text.

Pending native edits are combined in their evolving UTF-16 coordinates. A
batch within an ordinary line can use the existing incremental parser even
when several editing notifications precede presentation. Edits spanning lines
or changing context-sensitive syntax retain the full-parser fallback.

A single before/after run used the same 500,108-byte fixture, live preview,
iPhone 17 iOS 27 simulator, and optimized compiler configuration. The baseline
was `c579100`; the candidate was the working tree containing this cache change.
Numbers are edit-to-next-idle milliseconds, including synchronous formatting:

| Operation | Before | After | Reduction |
| --- | ---: | ---: | ---: |
| Median typing, 21 edits | 81.93 | 64.00 | 22% |
| Median deletion, 6 edits | 82.99 | 66.08 | 20% |
| Multiline insertion, 1 edit | 1248.32 | 550.77 | 56% |
| Maximum typing | 116.04 | 193.04 | Increased |

The candidate's first two typing samples were 193 and 187 ms. This single run
supports lower typical latency, not a worst-case improvement. The synchronous
native edit call remained roughly 50 ms. Autosave wait measured after editing
increased because less of the debounce elapsed during the shorter formatting
work; bulk insertion plus the subsequent save wait was about 1.78 seconds in
both runs. These are simulator measurements, not physical iPad frame latency.

Both runs performed 27 incremental parses and one full parse, with current
presentation at every idle checkpoint and exact text, caret, final syntax,
and saved-text checks passing. This sequential scenario measures snapshot
reuse; focused batched-edit tests separately verify one incremental parse for
multiple edits and formatting equivalence to a fresh full refresh.

Validation: 76 focused tests passed, with one existing headless insertion
indicator test skipped. Added coverage includes overlapping edits, edits
before prior edits, deletion, Unicode, replacement, storage switching,
attribute-only changes, and retained fallback for a batch containing a newline.

## Context-aware incremental regions

Syntax results now retain line boundaries where both fenced-code and emphasis
context are closed. Unmatched emphasis delimiters participate in this state
although they do not yet produce visible spans. Consequently, blank lines
alone are not assumed to be safe parser boundaries.

An edit restarts at the preceding cached safe boundary and reparses through
the affected lines. If the outgoing context remains open, the region grows
geometrically to subsequent cached boundaries until it closes or reaches EOF.
Regions above 65,536 UTF-16 units use the full parser. This bounds speculative
work while preserving the existing grammar. Unchanged syntax outside the
region is reused, and only the affected region needs layout attributes.
Ordinary newlines, balanced bold insertion, editing existing inline markup,
and edits within short multiline emphasis or code blocks now use this path.

Font runs are regenerated from cached spans because adjacent runs can cross a
safe parser boundary. This still visits document metadata; this change does
not claim constant work per edit or eliminate all full-document operations.

The same 500,108-byte simulator scenario produced 28 incremental parses and
zero full parses, compared with 27 incremental parses and one full parse in
the preceding cache implementation. The multiline insertion formatted 69
UTF-16 units rather than all 491,658 units. Text, caret, final syntax, and the
saved contents remained correct, with current presentation at every idle.

The initial run measured 67.34 ms median typing (previously 64.00 ms), 67.82 ms
median deletion (66.08 ms), and 781.55 ms for the single multiline insertion
(previously 550.77 ms). Because that last result was unexpectedly slower, a
second diagnostic build temporarily measured preparation and refresh time.
It measured 5.47 ms preparing the multiline syntax and 14.45 ms for the whole
formatting refresh, with 81.23 ms from insertion to idle. Median typing was
65.80 ms and deletion 69.76 ms. A separate 697 ms main-actor scheduling delay
still occurred during that run. The reason for the initial outlier is not
established; this is not evidence of consistently low end-to-end latency.
Temporary diagnostic instrumentation is not part of the app changes.

Validation: 78 focused tests passed, with the existing headless caret test
skipped. Coverage compares incremental syntax and cached restart boundaries
with full parsing across edits to newlines, emphasis, escaping, code fences,
Unicode, and unmatched delimiters, and compares native formatting with a
fresh refresh after newline and bold edits. Large context changes retain a
tested full-parser fallback. Physical iPad acceptance remains outstanding.

## Profiler diagnosis of the intermittent 700 ms stall

Two Instruments Time Profiler recordings of the same optimized 500 KB
simulator probe identified an additional rendering bottleneck. The second
recording reproduced a 761.41 ms multiline edit. Its signpost interval was
8.689079 to 9.450493 seconds; a 695.01 ms main-thread hang began at 8.765933
seconds and overlapped that edit.

Of the 695 main-thread samples during this hang, 71.7% included
`MarkdownPresentation.applyRenderingAttributes`, called from TextKit's
`renderingAttributesValidator` during viewport layout. 33.4% included
TextKit's `setTemporaryAttributes` implementation, with internal attribute
storage updates and memory movement visible in the stacks. These percentages
are inclusive and must not be added. No samples in this interval included
`MarkdownSyntax.parse` or `NoteSession.runSaveLoop`.

The first recording completed the multiline edit in 66.11 ms, but showed
709.60 ms and 614.19 ms viewport-layout hangs during initial animated
scrolling.
The second recording also showed long viewport-layout work before typing.
Thus this cost can occur during setup or after an edit; it must not simply be
excluded as startup noise. The explicit refresh timer does not include all
later TextKit/Core Animation layout callbacks.

The next rendering investigation should count validated fragments and
attribute writes, and check whether unchanged rendering attributes can be
retained or updates combined without breaking TextKit invalidation. The
profile locates the cost but does not establish whether the same fragments
are repeatedly validated or how many offscreen fragments are involved.
Performance checks should retain end-to-idle timing alongside isolated parser
and refresh timings, and exercise viewport movement after an edit.

## Physical iPad comparison after the cache changes

The 56.01-second iPad recording starting at 21:02:34 on September 21 contained
10 unresponsive intervals of at least 250 ms, totaling 7.08 seconds. This is a
different manual session from the earlier 45-second recording, so its totals
are not a controlled performance comparison.

Catalog/sync work accounted for 84.7% of main-thread sampled CPU during these
intervals. The 1.37-second hang at 50.368 seconds and 1.69-second hang at
52.661
seconds were almost entirely catalog work under `NotebookReplica.apply`,
`acceptSeed`, validation, and catalog decoding. The relevant replica and sync
coordinator are main-actor isolated. The simulator probe excludes this work.

Full parsing consumed about 48% of main-thread sampled CPU at 19-23 seconds
and 51% at 36-41 seconds. Most full-parser stacks came from the presentation
cache's fallback path. The profile contains no edit labels, so these windows
cannot conclusively be assigned to bold or highlighting actions.

A separate synthetic parser check confirmed a relevant difference: inserting
unfinished `**target words` in the middle of a note with more than 65,536
UTF-16 units following it requires a full-parse fallback. Unfinished
`==target words` remains line-local and incremental. Both are incremental at
EOF, and completed balanced bold was incremental in the same middle-of-note
check. All returned incremental results matched a fresh full parse. The
existing end-of-note benchmark therefore misses this open-context case.

Bold also changes font metrics, whereas highlighting supplies a rendering
background color. However, the rendering-attribute callback that dominated
the simulator stall accounted for only about 0.1% of main-thread sampled CPU
in this iPad session, and about 0.01% during its unresponsive intervals. The
simulator rendering bottleneck remains real but was not the dominant source
of freezes in this physical-device recording.

Next priorities from this recording are catalog processing on the main actor
and repeated full parsing while a formatting delimiter remains open in the
middle of a large note. Extend the benchmark to type opening markers, several
letters, and closing markers as separate edits in the middle of the fixture;
a single insertion of an already-balanced bold phrase does not cover this.

## Paragraph-scoped emphasis

Unmatched bold and italic delimiters now stop at blank lines, including
space/tab-only lines and CRLF paragraph separators. The parser also resets
emphasis at heading, list-item, and fenced-code boundaries. A single newline
within ordinary paragraph text still permits multiline emphasis. These
changes cover the supported block syntax; they are not a claim of complete
CommonMark conformance.

Multiline bold was already parsed and styled correctly in the checked cases.
New native font checks confirm bold on both lines and plain text in the next
paragraph in source and live-preview modes, on macOS and the iOS simulator.
No separate multiline-rendering fix was needed. The semantic bug fixed here
was matching emphasis across separate paragraphs or blocks.

The earlier synthetic fallback fixture had no blank lines: it was one giant
paragraph. Such genuinely long inline context may still require a full parse.
The extended native benchmark instead uses the existing short paragraphs and
blocks in the 500,108-byte fixture, with ten individual middle-of-note edits.

One before/after simulator run with synchronous formatting measured:

| Action, median edit-to-idle | Before | After | Reduction |
| --- | ---: | ---: | ---: |
| Opening bold markers, 2 edits | 632.92 ms | 154.29 ms | 76% |
| Typing inside unfinished bold, 6 edits | 568.04 ms | 83.25 ms | 85% |
| Closing bold markers, 2 edits | 560.38 ms | 84.05 ms | 85% |
| Ordinary typing at EOF, 21 edits | 64.43 ms | 67.48 ms | -5% |

All ten middle edits changed from full parses to incremental parses. Exact
source, caret, session text, full-parser agreement, and autosave reload checks
passed. The ordinary typing difference is from a single run, not evidence of
a statistically established regression. Bulk insertion was 81.65 ms before
and 778.13 ms after, reproducing the separate intermittent rendering stall
previously profiled; this change does not resolve that bottleneck. Physical
iPad timings and catalog/sync hangs remain separate follow-up work.

Focused regression validation: 101 tests passed, with the existing headless
insertion-indicator test skipped. Coverage includes multiline emphasis,
paragraph separator edits, block boundaries, Unicode, incremental/full-parser
agreement, and a large-note check that unfinished bold reparses fewer than
256 UTF-16 units. The benchmark now reports per-edit parse counts and formatted
lengths so future changes can expose this specific fallback regression.
