# iPhone editor regression gate

The native workflow and UI workflow now share the coverage contract in
[Test foundation](test-foundation.md). The iPhone UI lane retains the fresh,
owned iPhone 12 Pro Max with an available iOS 27 runtime. The software keyboard
is required; missing or skipped cases fail. Global Simulator settings stay
unchanged.

Run the UI plan locally with an owned simulator and a new evidence directory:

```sh
python3 scripts/run_ui_foundation.py iphone \
  --evidence-root /tmp/meh-ui-evidence
```

The full native comparison runs with
`scripts/run_native_editor_baseline_parity.sh`. CI also checks all 47 strict
editor guards inside its current result. The two older runners were removed
because the unified execution owns their coverage and evidence.

## Automatic coverage

The strict native subset requires 47 passing iOS tests, with no skips:

| Class | Tests |
| --- | ---: |
| `MarkdownEditorScrollPaddingTests` | 12 |
| `MarkdownParagraphGapTests` | 9 |
| `MarkdownHeadingGeometryTests` | 1 |
| `MarkdownRenderingAttributeTests` | 1 |
| `MarkdownRenderingIndexTests` | 3 |
| `MarkdownNativeTextChangeTests` | 8 |
| `MarkdownSelectionSnapshotTests` | 1 |
| `NativeEditorIntegrationTests` | 12 |

These cover gap insertion/deletion, neighbor refresh, unusual separators,
table metrics, heading typography, native EOF caret geometry, focus
rendering, bounded viewport changes, literal editing and undo. The heading
test includes 36 font/mode/text geometry comparisons.

The iPhone UI plan uses three keyboard journeys, with no skips:

- `testSourceColdFocusAndReturnKeepInsertionVisible`
- `testPreviewColdFocusTypesIntoTappedParagraph`
- `testPreviewTypingAndListReturnKeepInsertionVisible`

These retain cold focus, typing into the intended paragraph, visible
insertion and native list Return behavior with exact literal source checks.
Cold-focus cases check the tapped paragraph above the keyboard before the
first character, then verify its exact insertion location. Each new line
uses distinct visible text. Blinking caret color is not an acceptance oracle.
Two History journeys cover closing while indexing, browsing without changing
the current note, and restoring a separate note without changing the original.
They run on the specified phone geometry; this is not an all-device UI matrix.

## Evidence and limits

The unified UI artifact preserves source, plan, toolchain and product hashes,
compiled discovery, exact results, screenshots, per-drag recordings and stage
timings. Raw result bundles remain on failure. Cancellation removes only the
owned simulator and build directory. GitHub retains evidence for 14 days.
The full native artifact preserves its pinned baseline and current results.
The retained native inventory is expected to contain 244 methods: 243 that
passed the preceding full run and one opt-in performance skip, after retiring
three known failing methods. This projection requires fresh execution on the
changed head. The frozen baseline retains its historical failures.
Comparison allows only those three explicit removals; every retained current
method must pass, with no unexpected missing methods or new skips. The 47
strict guards remain intact. Retirement removes their specific Find and
first-layout position assertions; it does not establish those outcomes as
correct. Other saved-position tests remain, but the removed first-preview
anchor test no longer supplies an automated opening-frame check.

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
