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

Full-document parsing is retained when text changes. This preserves the
meaning of edits that open or close a fence and affect later paragraphs.
Whole-document layout-attribute construction also remains; optimizing that
requires a separate incremental-style design and is not claimed here.

## Reproduce

Use an existing iOS 27 or newer simulator. The runner reuses the existing
Editor Quote Check test application and generates a fictional note in memory.
It never opens the notebook, private notes, or iCloud. The chosen test app is
replaced on the selected simulator; no new app identity is introduced.

```sh
scripts/run_editor_performance_check.sh SIMULATOR_UDID \
  2ac68f4 livePreview 150 /tmp/editor-before.json
scripts/run_editor_performance_check.sh SIMULATOR_UDID \
  working-tree livePreview 150 /tmp/editor-after.json
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
