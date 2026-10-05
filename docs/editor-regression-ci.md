# iPhone editor regression gate

The `iPhone editor regressions` workflow runs on the Xcode 27 runner. It
uses a fresh, owned iPhone 12 Pro Max simulator with an available iOS 27
runtime. It requires the software keyboard and fails if the expected
tests are missing or skipped. It does not change global Simulator settings.

Run locally with `scripts/run_editor_regressions.sh`, after coordinating
simulator ownership. The script creates a package-only temporary directory
with source links to the checkout and a regular copy of `Package.swift`.
The copied manifest filters out the unrelated `NotebookAppModel` product
and `NotebookAppModel`, `NotebookAppModelTests` and `NoteCoreTests` targets.
All existing native target definitions and paths stay intact. The aggregate
`MehCore-Package` scheme then builds its existing iOS test runner without
selecting the adjacent app project. UI tests use the shared `meh.md iCloud
Dev` scheme and explicit `-only-testing` selection. Test data are fictional,
unique preview notebooks with automatic sync disabled; ordinary notebooks
are not opened. Native tests mount editors with fixture bindings.

## Automatic coverage

The native stage requires 35 passing iOS tests, with no skips or failures:

| Class | Tests |
| --- | ---: |
| `MarkdownEditorScrollPaddingTests` | 12 |
| `MarkdownParagraphGapTests` | 9 |
| `MarkdownHeadingGeometryTests` | 1 |
| `MarkdownRenderingAttributeTests` | 1 |
| `NativeEditorIntegrationTests` | 12 |

These cover gap insertion/deletion, neighbor refresh, unusual separators,
table metrics, heading typography, native EOF caret geometry, focus
rendering, bounded viewport changes, literal editing and undo. The heading
test includes 36 font/mode/text geometry comparisons.

The UI stage requires exactly these seven passing tests, with no skips:

`EditorScrollTypingUITests`:

- `testSourceReopeningKeyboardNearEndRevealsCaret`
- `testLivePreviewReopeningKeyboardNearEndRevealsCaret`
- `testSourceTypingAtEndKeepsCaretStable`
- `testLivePreviewTypingAtEndKeepsCaretStable`
- `testLivePreviewListReturnAtEndKeepsCaretStable`
- `testLivePreviewTypingOnEmptyEndLineKeepsCaretStable`

`EditorLongNoteTapUITests`:

- `testTapNearEndReplacesPreviousEOFSelection`

They check exact source insertion, the intended paragraph, visible caret
pixels, and text anchors after first letters and repeated Returns. Their
13/15-point monospaced fixtures and OCR/tap coordinates were validated on
the specified phone geometry; this is not an all-device UI matrix.

## Evidence and limits

Each run preserves the source revision, three production source hashes,
original/temporary manifest hashes and filter list, simulator inventory,
build/test logs, both result bundles, summaries, exact test identifiers and
screenshot attachments. A failed test stage keeps its continuous recording.
Successful-stage recordings are removed. Cancellation cleans only the
owned recording process, simulator and temporary build directory; evidence
remains available. GitHub retains the artifact for 14 days.

The original interactive canceled Home gesture remains a manual acceptance
check. Its temporary local acceptance harness uses a private XCTest event
synthesizer and is not part of this gate. Native padding/geometry tests
protect measured causes but do not reproduce that system gesture.

The UI assertions inspect positions after an action. They do not detect
every transient frame: an earlier candidate passed settled-position tests
while briefly showing an earlier section during keyboard opening. Native
video/frame review and physical-phone acceptance remain separate manual
evidence. A recording alone is not an automated motion assertion.

This gate is separate from the existing parser/catalog/native performance
workflow. Passing scroll checks does not waive its performance budgets.
