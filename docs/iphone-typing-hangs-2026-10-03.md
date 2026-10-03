# Physical iPhone typing hangs: October 3, 2026

The owner's Instruments recording confirms costly whole-note comparisons
while typing in the real notebook screen. This is baseline diagnostic evidence;
it does not establish the candidate fix's performance on a physical device.
Only sanitized timings and function names are recorded here. The raw trace,
note contents, device identifiers, and local filesystem paths are omitted.

## Build identity and measurement scope

The app debug dylib UUID was `7778FF27-D341-39FF-B335-91E000C43E2A`.
It exactly matches the local iCloud Dev version 0.10.6, build 1. The matching
build log contains the app's Swift compiler flag `-Onone`. This recording
therefore profiles the Debug-iCloud build, rather than an optimized App Store
binary. It is distinct from the previously reported installed release build
28; matching the version does not make their optimization settings identical.

The recording spans 25.187 seconds. Instruments identified 50 main-thread
responsiveness events: five Hangs, eight Microhangs, and 37 Brief
Unresponsiveness events. Their combined duration was 11.994 seconds.
Main-thread sampling
provided 27,863 samples. Event durations measure the recorded stalls, while
sampled cycle shares describe CPU attribution; they are different measures.

## Recorded hangs and attribution

Five events lasted at least 500 ms. Times are offsets into the recording.

| Start | Duration | Observed work |
| ---: | ---: | --- |
| 1.628 s | 763 ms | Startup catalog decoding |
| 7.840 s | 618 ms | Parsing during note opening |
| 10.149 s | 681 ms | Toolbar query and whole-string comparison |
| 11.539 s | 828 ms | First-activity catalog save and compression |
| 13.477 s | 1,692 ms | SwiftUI/string comparisons plus catalog work |

The 11.539-second event contains `recordRecentActivity`, `persistCatalog`,
`NotebookCatalogDocument.snapshot`, `Document.save`, and Rust compression
frames. It is evidence for synchronous catalog serialization during activity
recording, rather than evidence that every keystroke saves the catalog.

The largest event includes approximately 71.3% string/SwiftUI comparison and
21.1% catalog inclusive sampled cycles. Its comparison stacks include SwiftUI
binding and deep comparison work. These inclusive categories must not be
added as independent exclusive costs, and the complete event must not be
attributed to a single completion-text setter.

A separate event at 21.099 seconds lasted 314 ms and explicitly contains:

```text
NotebookView.linkCompletionText.setter
StoredLocationBase.set(_:transaction:)
AGDispatchEquatable
Unicode NFC normalization and string comparison
```

That stack connects the whole-note state assignment to repeated typing stalls.
It complements the state-only simulator comparison, where conditional
assignment reduced the 500 KB typing median from 1,802.95 ms to 125.51 ms.
The simulator result establishes causality in that controlled fixture; the
physical baseline stack establishes that the same path runs on the iPhone.

## Repeated typing window

For the selected 15.15–24.20-second window, inclusive main-thread sampled
cycle shares were:

| Path | Share |
| --- | ---: |
| `reportLinkSelection` | 16.5% |
| `preparedCommandSyntax` | 11.5% |
| `commitEditorText` | 9.9% |
| `layoutViewport` | 0.4% |

The window contains 15,755 main-thread samples. These shares are scoped to
this window and are not per-keystroke latency measurements. The toolbar stack
contains `MarkdownSyntaxCache.result(for:)` and `Sequence.elementsEqual`,
confirming that preparation was followed by another whole-string UTF-8 scan.
The viewport share does not support prioritizing a viewport-layout rewrite
for this recording.

## Introduction history and final scope

The completion text assignment was authored in `dba14f74` on September 30 and
merged with PR #173 in `1be4d84` on October 2, with source version 0.9.0.
This is a recent amplifier of an existing editor and notebook screen.

First-activity recording reached the catalog save path through PR #130,
merged in `68cc19d` on September 26. Full catalog serialization was already
present on September 13. The recorded catalog work therefore predates the
connected-notes state assignment.

Native table toolbar queries entered through PR #138, merged in `585a678`
on September 26. PR #191, merged in `1378bf5` on October 3, prepared observed
native storage but still called `result(for:)` afterward. That retained the
whole-string comparison visible in the recording.

The narrowed candidate avoids inactive completion-text assignment, commits
validated native deltas when the editor revision matches, and returns prepared
syntax directly for native toolbar queries. Stale revisions keep the existing
merge path; arbitrary-string cache callers keep exact content validation.
The EOF formatting and viewport-deferral experiments were reverted entirely.
Extreme long-line benchmark failures remain exploratory evidence, not a
claimed fix. Catalog startup and first-activity work are addressed by the
[catalog follow-up](editor-catalog-performance.md).

See the [real notebook investigation](editor-typing-regression.md) and its
[serial simulator reports](
benchmarks/editor-real-notebook-2026-10-03.json) for the controlled comparison.
Three final narrowed-candidate simulator reports pass their timing and
correctness checkers. Full local validation passed (964 Swift tests, nine
expected skips), together with the iCloud Dev link-navigation UI test. PR
CI and review remain pending. Physical-device improvement has not been
verified; this trace is baseline evidence.

## Bounded full-parser follow-up

The opening-note stack includes `appendPairedSpans`, `isExactPair`, and
UTF-16 character access. Full parsing now copies literal UTF-16 units once
into a contiguous Foundation string, including inline table-cell parsing.
An isolated `==` or `~~` pair is checked using its fixed boundaries rather
than recounting the remaining delimiter run at each position. Escape, code,
line, table, and comment policies remain unchanged. Incremental parsing's
whole-source bridge is unchanged.

A serial macOS 27 CPU benchmark used fictional Unicode paragraphs containing
emoji, decomposed accents, Japanese text, highlights, and strikethrough.
Seven samples per size and configuration produced these full-parse medians:

| Configuration | Size | Baseline | Candidate |
| --- | ---: | ---: | ---: |
| Debug | 50 KB | 27.73 ms | 19.37 ms |
| Debug | 500 KB | 258.87 ms | 183.81 ms |
| Optimized | 50 KB | 18.33 ms | 10.21 ms |
| Optimized | 500 KB | 171.46 ms | 97.15 ms |

The complete syntax-result hashes matched at both sizes in both
configurations. Focused parser tests passed 35 cases, with one expected
opt-in timing skip. The [raw parser reports](
benchmarks/editor-full-parse-2026-10-03.json) retain samples and hashes.
This reduces measured parser cost; full parsing remains synchronous and
nonzero. The fixture does not reproduce the owner's note or prove that the
618 ms physical opening stall is eliminated. Updated full-screen simulator
checks and physical-device verification remain separate work.
