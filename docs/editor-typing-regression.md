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
Xcode 27 runner. It opens the actual `NotebookView` editor in a new iPhone
iOS 27 or newer simulator and removes only that simulator afterward. It runs
a mixed 50 KB live-preview note, a standard 500 KB note, and a 50 KB note
near a table. The runs are serial and use local storage, without opening a
user's notebook or contacting CloudKit.

The regression escaped because the large-note benchmark was opt-in, outside
the regular Swift test run, and had no timing ceiling. CI now runs
deterministic checker tests and a native simulator workflow with timing
gates. The 0.10.6 baseline control and candidate run serially on each pull
request, using the same runner and benchmark harness. The catalog control
must fail its heartbeat gate. The candidate must improve the 500 KB native
synchronous and to-idle medians and p95 values by at least 20% against that
baseline, while passing the absolute limits below. Its literal text,
selection, saved text, final presentation, and syntax results must remain
correct. Native comparisons also require a matching literal-fixture SHA-256.

- Text, selection, saved text, and final presentation checks all pass.
- Standard and mixed measured edits perform zero full parses and exactly one
  incremental parse; the nearby-table case permits its validated structural
  fallback. Per-step parse counts must match report aggregates.
- Expected typing, deletion, bulk insertion, and middle-bold samples exist,
  with bounded formatted ranges and current presentation at each idle point.
- Required timings are present and finite. Repeated typing, deletion, and
  middle-bold edit p95 synchronous limits are 50 ms at 50 KB and 150 ms at
  500 KB. To-idle limits are 250 ms for standard 50 KB, 500 ms for the
  nearby-table 50 KB case, and 1,000 ms for standard 500 KB.
- The single bulk-insert sample has separate to-idle ceilings: 500 ms at
  50 KB and 2,000 ms at 500 KB. Synchronous limits remain 50 ms and 150 ms,
  respectively. This is a single-sample ceiling, not a p95 threshold.

The Unicode full-parser benchmark takes 21 samples at 50 KB and 500 KB in
each of three balanced independent launches per variant. The median of run
medians and median of run p95 values must both improve by at least 20% over
the 0.10.6 baseline on the same runner. Current and optimized reference
launches retain absolute ceilings of 50 ms at 50 KB and 300 ms at 500 KB.
Fixture byte count, UTF-16 length, and syntax hash must match in every run.
The optimized reference comparison uses median only: current must remain
within 120% of reference plus 2 ms at 50 KB or 5 ms at 500 KB.

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


## Follow-up: the real notebook screen

The owner reported that version 0.10.6 still felt slow when typing at the end
of an existing long note on a physical iPhone. The installed release was
build 28, from main `1378bf5`, published by pipeline `37125466475`.

PR #191 measured a fresh note hosted directly in `NotebookNoteEditor`. That
included native editing, NoteSession, Automerge, and local saving, but omitted
`NotebookView`, its local catalog, and its real edit and selection callbacks.
The earlier benchmark's explicit notebook/catalog limitation matters: it did
not establish typing performance on the complete app screen.

The follow-up probe hosts the real `NotebookView` with a disposable local
notebook. It uses the same fictional note and serial optimized iPhone 18 Pro
simulator runs on iOS 27, without CloudKit. The baseline uses the production
sources shipped in 0.10.6; only the probe is changed to host the full screen.
Both versions preserve literal text, caret position, final presentation, and
saved text. These are fresh-note simulator timings, not a repeat of the
owner's physical-device session or existing document history.

| Full-screen source state | Size | Typing to idle median | Maximum |
| --- | ---: | ---: | ---: |
| 0.10.6 baseline | 50 KB | 204.00 ms | 225.51 ms |
| Combined candidate | 50 KB | 24.19 ms | 86.18 ms |
| 0.10.6 baseline | 500 KB | 1,802.95 ms | 1,883.50 ms |
| Combined candidate | 500 KB | 98.60 ms | 129.76 ms |
| State assignment fix only | 500 KB | 125.51 ms | 417.65 ms |

The baseline's synchronous typing call medians were only 6.81 ms at 50 KB and
48.05 ms at 500 KB. Most of the measured delay therefore occurred after the
native edit call returned. The four baseline/combined runs performed zero
full parses and 38 incremental parses, so those checks alone did not expose
the screen-level delay.

One suspect was the selection callback assigning the entire note to
`linkCompletionText` even when no link completion was shown. That observable
state belongs to `NotebookView`; each assignment can invalidate the complete
screen. The assignment entered in `dba14f74` on September 30, with the
connected-notes work in PR #173. The candidate retains completion text only
while completion is active. It also passes validated native insertions and
deletions to NoteSession, avoiding whole-text CRDT updates and redundant
CRDT text extraction when the editor revision still matches. Stale revisions
retain the existing merge path.

A separate optimized core benchmark measured the old whole-text commit plus
CRDT text extraction at about 33 ms for a fresh 500 KB document and 36 ms
after 400 prior typing/deletion operations. Snapshot serialization measured
about 1.4 ms in that controlled fixture. This does not reproduce the owner's
history, but it does not explain the baseline screen's roughly 1.8-second
per-character delay. The new native delta path targets the remaining core
work separately from screen invalidation.

The state-only comparison retains the shipped core and editor paths and
changes only the selection callback's conditional state assignment. Its
500 KB median fell from 1,802.95 ms to 125.51 ms, establishing that this
assignment caused the dominant delay in this fixture. The worst sample was
still 417.65 ms. Adding native delta commits reduced the combined candidate's
median further to 98.60 ms. These are individual serial runs; they support
attribution in the tested setup, not stable worst-case or hardware guarantees.

A mixed 50 KB candidate fixture with frontmatter, comments, and horizontal
rules measured 25.53 ms median typing to idle and 81.76 ms maximum, with no
full parses. Additional note shapes exposed remaining work: a nominal 50 KB
fixture with a 65,537-unit trailing line is about 115 KB in total. The initial
candidate measured 258.66 ms median and 266.05 ms maximum typing to idle on
that shape, plus 302.11 ms for the single multiline insertion. It performed
28 full parses because the existing 65,536-unit speculative parse limit was
exceeded. A nearby-table fixture also retained 28 expected full parses,
measuring 78.58 ms median and 121.96 ms maximum typing to idle.

The long-line and nearby-table runs are exploratory shape evidence. The
experiment that limited EOF attribute rebuilding and deferred viewport layout
was reverted entirely. It did not establish a fix for the long-line delay.
The existing parser limit and full-formatting fallback remain unchanged.

The final scope follows the physical iPhone profile: retain completion text
only while completion is active, commit validated native deltas when the
editor revision matches, and return the prepared syntax cache directly for
native toolbar queries. The toolbar accessor previously prepared the native
storage and then compared the entire UTF-8 string again through `result(for:)`.
The arbitrary-string accessor retains that exact comparison for callers
without native storage identity. Earlier combined reports predate the direct
prepared-cache accessor. The
final narrowed candidate passes all three native report checkers:

| Final fixture | Typing to idle median | Maximum |
| --- | ---: | ---: |
| Mixed 50 KB | 22.09 ms | 84.59 ms |
| Standard 500 KB | 94.93 ms | 133.00 ms |
| Nearby table 50 KB | 77.61 ms | 136.31 ms |

The mixed 50 KB run compiled the optimized probe from the working tree based
on `1378bf5`. The other two runs reused that installed binary through a
temporary manual rerun harness, with production source unchanged. Their
source identity is caller supplied; the probe does not embed a source hash.
The mixed and standard reports each contain zero full parses and 38
incremental parses. The nearby-table report retains 28 expected full parses
and ten incremental parses. Full local validation passed: 964 Swift tests
with nine expected skips,
35 sync-tool Python tests, and 34 performance-gate Python tests. The iCloud
Dev link-navigation UI test also passed. Exact-head PR CI and review remain
pending; simulator checks do not establish physical-device improvement.

The owner's [sanitized physical iPhone profile](
iphone-typing-hangs-2026-10-03.md) independently identifies repeated completion
state comparisons, toolbar string scans, and core commits. It also separates
startup catalog decoding and first-activity catalog serialization from typing.
The sampled viewport layout contribution was only 0.4% during the selected
typing window, so the final fix does not change viewport rendering behavior.

The [full-screen reports](
benchmarks/editor-real-notebook-2026-10-03.json) retain the finished samples
and source metadata. The baseline reports' original `measurement_note`
predates full-screen instrumentation and incorrectly excludes the catalog;
these reports have `host: notebook` and include the local notebook screen.
The physical profile records baseline hangs, not a before/after device test.
Candidate physical-device performance, long-lived document history, and live
CloudKit remain separate verification work.

The current frozen optimized reference is commit `3698141`; it supersedes
the historical `editor-performance-reference-0.10.7` control. Parser gates
use the three balanced launches and median reference allowance described
above. Native 500 KB probes use three paired independent launches; current
aggregate medians must remain within 120% of reference plus 10 ms. Every
native launch retains all absolute wall-clock limits. The slower 0.10.6
comparison remains a negative control alongside these regression checks.
Reference and candidate use the same fictional input and match literal or
syntax checksums. This catches partial slowdowns that still beat 0.10.6.

The first character remains in the measured samples; the probe does not
warm it away with a discarded edit. A CI reference run measured a 1,736 ms
first edit at 500 KB, followed by roughly 130 ms edits. Its cause is not
isolated, and physical-device before/after verification remains open.
Because p95 of 21 typing samples omits one outlier, CI also bounds the
first character at 500 ms for 50 KB or 2,000 ms for 500 KB. Every subsequent
character must finish within 500 ms, including the nearby-table case.
These simulator ceilings are regression controls, not physical latency
guarantees.

### Balanced parser launches

CI run `37733656194` measured a 500 KB current median of 138.866 ms
against a baseline of 239.333 ms (about 42% faster). Its p95 was
220.312 ms against 259.564 ms, missing the unchanged 20% improvement
requirement of 207.651 ms. The current samples showed a slow middle
section and returned to about 130 ms. The optimized reference median
was 114.860 ms; current passed its 142.832 ms allowance. This describes
the observed variation; it does not establish a host-related cause.

The workflow now builds baseline, frozen optimized reference, and current
before measuring any of them. Three independent `swift test --skip-build`
launches per variant rotate their order: baseline/reference/current,
reference/current/baseline, then current/baseline/reference. No catalog
work or compilation separates these nine launches. Every report must
contain the same two fixture identities and 21 valid samples per fixture.
Current and optimized reference launches must pass the absolute median
and p95 ceilings. The historical baseline still validates structure and
fidelity; its old parser may legitimately exceed those ceilings. Missing
reports, reused report paths, changed syntax hashes, and unexpected or modified
control production sources fail closed.

Relative gates compare the median of the three run medians and the median
of the three run p95 values. Current must still improve both metrics by
20% against baseline. Its median must remain within 120% of the optimized
reference plus 2 ms at 50 KB or 5 ms at 500 KB. A slow single launch cannot
hide an absolute violation; repeated tail or median regressions still fail.
All nine raw reports and launch logs are retained, and native editor probes
run after a parser failure so that one gate cannot suppress their evidence.

The actual nine-launch protocol also passed locally after prebuilding.
At 500 KB, current median-of-medians/p95 were 88.957/92.901 ms,
baseline was 182.701/187.524 ms, and optimized reference was
89.396/94.298 ms. These validate the collection method; they do not
represent a new parser improvement in this PR. All 36 timed test cases
passed. [Raw reports](benchmarks/parser-paired-performance-2026-10-08.json)
record every launch on the local Apple M3 Max / macOS 27.0.1 host.
