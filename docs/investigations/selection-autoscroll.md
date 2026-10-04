# Selecting text without automatic scrolling

Investigated on 2026-10-04 at main commit `03864b0`, using the iCloud Dev
build on the existing AI iPhone simulator with iOS 27. The initial
investigation used a broad diagnostic prototype. A narrower implementation
is described below.

## Result

Suppressing non-pan content-offset requests stopped the native selection
autoscroll in plain UIKit and in meh.md's Live Preview editor. Manual
scrolling retained the selection, and native handles could adjust that
selection again after scrolling back to its endpoint.

Suppressing only range/rectangle reveal requests did not stop autoscroll.
UIKit's edge-selection movement used animated content-offset requests in
the observed tests. This gives us a concrete control point to investigate
for a production implementation, without replacing native selection UI.

## Experiment

Three agents supported API review, editor code review, and serialized
simulator testing. The API review checked Apple documentation and the
installed iOS 27 UIKit headers. The code review identified Live Preview
layout refreshes, explicit destination/position scrolling, and keyboard
geometry as separate movement owners.

The temporary app route displayed an 80-paragraph fictional note directly.
It did not initialize NotebookWorkspace, register sync notifications, or
schedule backups. No personal or development notes were opened.

The probe compared a plain TextKit 2 text view with the actual
MarkdownEditor in Source and Live Preview modes. It instrumented range
reveal, rectangle reveal, content-offset assignment, animated offset
requests, same-size bounds changes, and selection events.

Preparation programmatically selected five characters at `Trail 8` and
centered the endpoint. XCTest then dragged the native selection handle
toward or past the visible edge. The edge gesture held for three seconds
20 points beyond the viewport. The interior gesture held for 1.5 seconds
12 points inside it.

A separate Source/Live Preview test created a selection by double-tapping
visible text. Keyboard appearance and initial selection were recorded
before relaunching for the handle tests.

## Observations

Offsets below are viewport positions in points. They describe these
specific harness runs, not a universal UIKit speed or device guarantee.

| Editor / variant | Edge-drag offset | Selection length |
| --- | --- | --- |
| Plain / baseline | 267.7 -> 4471.0 | 5 -> 6559 |
| Plain / reveal guard | 267.7 -> 4471.0 | 5 -> 6606 |
| Plain / offset guard | 267.7 -> 267.7 | 5 -> 282 |
| Source / baseline | 436.3 -> 5944.0 | 5 -> 6323 |
| Source / offset guard | 436.3 -> 438.7 | 5 -> 186 |
| Live Preview / baseline | 436.3 -> 6289.0 | 5 -> 6785 |
| Live Preview / offset guard | 436.3 -> 436.3 | 5 -> 189 |

The plain interior gesture increased selection length from 5 to 276 without
moving the viewport. The plain offset guard intercepted 42 animated offset
requests during the edge gesture. Live Preview intercepted 50.

Manual scrolling under the guard remained possible. In plain UIKit, the
offset moved from 267.7 to 576.7 while retaining range `644 + 5`. In Live
Preview, it moved from 436.3 to 687.3 with the same range retained. After
scrolling back, further handle adjustment extended the selection while
keeping its starting offset at 644. The keyboard remained visible.

Genuine double-tap selection of the first visible word produced range
`0 + 5`, showed the keyboard, and kept the offset at zero in Source and
Live Preview. This did not reproduce unwanted movement at selection onset.
It does not cover initial selection at arbitrary positions in a real note.

## Important Source-mode limitation

The Source-mode synthetic setup displayed its highlight around Trail 12/13
despite reporting a range at Trail 8. The reported handle coordinates
matched the visible handle. When dragged, UIKit changed the selection
anchor from 644 to 1106 in both the baseline and guarded runs.

This is a mismatch between synthetic selection/layout state and displayed
geometry. Source content height also changed substantially after layout.
We did not investigate that further in this task. These Source runs show
viewport suppression, but do not establish correct anchored extension.
The plain and Live Preview captures displayed the expected Trail 8 range.

## Slow scrolling near the edge

The first slow-edge experiment required an endpoint within 24 points of
the visible edge, a 350 ms dwell in native scroll requests, and a cap of
30 points per second. It stayed fixed because the selected endpoint
snapped 34 points above the viewport bottom, even though the finger crossed
the edge. It therefore did not validate the dwell or speed limit.

One bounded follow-up widened the endpoint band to 40 points. It moved
79.3 points during the three-second edge hold, compared with 4203.3 points
in the plain baseline. The selected range grew from `644 + 5` to
`644 + 421`. Manual scrolling retained the selection; after returning,
the handle could extend it again while the viewport moved slowly.

This is consistent with the configured 30 points/s budget. Exact dwell
timing and instantaneous velocity were not independently verified. This
is an endpoint-based approximation; a finger-based edge policy would need
dependable gesture lifecycle and pointer-position information.

## Production direction

Keep native UIKit selection and start with controlling its animated offset
requests during selection adjustment. The diagnostic offset guard is too
broad to ship: it suppresses all non-pan movement with a ranged selection,
including legitimate keyboard, Find, navigation, and accessibility work.

Before treating this as a fix:

1. Narrow the intercepted path and give explicit app navigation, editing,
   keyboard/layout changes, and restoration permission to move the viewport.
2. Preserve the selected UTF-16 range during manual pan and deceleration.
3. Test selection creation and both handles at arbitrary positions, with
   the keyboard shown and hidden, including wrapped text, emoji and tables.
4. Verify the exact gesture on a physical iPhone. Simulator gesture success
   and screenshots cannot establish physical interaction quality.

Do not replace delegates or identify private UIKit recognizer classes to
infer a handle-drag session. No documented native selection-autoscroll
switch or accessor for UITextView's built-in text interaction was found.

If public interception proves unreliable, Apple supports custom gestures
with native selection display via UITextSelectionDisplayInteraction. That
is a larger editor change and should be a separate decision.

## Reproduction and evidence

The initial diagnostic sources and integration patch are archived locally
under the follow-up path given below. The narrower candidate's reproducible
probe is committed under `Tools/SelectionLab/Implementation`. These probes
are excluded from normal app builds after unstaging. No diagnostic app hooks
remain in production source files.

The task's logs, result bundles, JSON traces, and exported captures are in
`/tmp/meh-selection-lab-20261004`. These temporary files can disappear.
Automated tests were observation probes: a test passing means its actions
completed, not that the original physical-device issue is fixed. The
conclusions above use the range, offset, and screenshot evidence.

Existing PR #179 targets selection-driven Live Preview layout changes.
This task used current main as the baseline; it did not assume that PR
fixed the user's issue and did not merge or modify it.

- [Existing selection PR][pr]
- [Apple text interactions][interaction]
- [Apple native selection display session][display]

[pr]: https://github.com/AndreasSko/meh.md/pull/179
[interaction]:
  https://developer.apple.com/documentation/uikit/uitextinteraction
[display]: https://developer.apple.com/videos/play/wwdc2023/10058/

## Approach 1 implementation

The candidate is on main `2950b5b`, with app version `0.10.17`. It intercepts
animated `setContentOffset` requests in the focused iOS editor while a
nonempty selection exists. Nested synchronous scopes permit deliberate
range/rectangle reveals, focus changes, edits, and layout. Keyboard input,
marked text, undo/redo, Find, and accessibility state also permit movement.
No private UIKit recognizers or delegates are used. The production guard has
not changed during this follow-up.

The implementation probe mounts the actual MarkdownEditor with a fictional
80-paragraph note. It creates a selection by double-tapping text after
manual scrolling, and reads native selection, geometry, and offset state.
It does not set the selection or force TextKit layout. The small host
shrinks above the keyboard during editing, as production does. It mirrors
production's conditional keyboard-safe-area behavior by ignoring that area
only while Find is visible.

Edge suppression and forward manual scrolling with the selection retained
have passed consistently in Source and Live Preview. An earlier Live
Preview run also preserved native selection through return scrolling and
exact replacement. The latest Live Preview run confirmed the sequence:
range `1446 + 6` became `1446 + 125` at fixed offset `942.0`; manual scrolling
moved to `1265.7` and returned to `936.3` with the range unchanged. Native
handle adjustment changed it to `1446 + 31`, retaining its anchor, and typing
replaced exactly that range. Source continuation results varied; its later
return gesture changed the range or failed to grab the handle. Reliable
Source acceptance remains unverified.

The corrected app-hosted fixture uses a connected `UIWindowScene` and waits
for native scroll reveal to settle before checking visibility. All six
focused UIKit regression tests passed in the full current package with zero
skips. The headless package runner has no connected scene and cannot drive
these native scroll animations; its earlier three failures were fixture
limitations, not reproduced production failures. The package now includes
the backup-scheduler dependency required for iOS compilation. The final
macOS native-editor suite ran 293 tests with zero failures and two skips:
an opt-in performance test and a native insertion-indicator test requiring
an app host. The final iCloud Dev build-for-testing passed after removing
all temporary diagnostic launch hooks.

Find visibility failed in both the candidate and unchanged main in the
same corrected host. Both exposed range `6500 + 15` for ORBITAL LANTERN,
but the endpoint was below the visible editor. This does not establish a
Find regression caused by this guard. Normal-screen Find coverage remains
required; successful range reveal in the six UIKit tests is a separate check.

The parallel work is now titled "Note jumps" and targets PR #202, committed
as `a810015`. It changes stable bottom padding and content size without a
Return-key override. Its draft returned after a keyboard-tap regression.
Static integration resolved the class-top insertion and preserves this
candidate's layout allowances and the padding changes. The combined iCloud
Dev build passed. In its gesture run, the selected endpoint was at the
keyboard edge, and the drag did not change the range. Find also failed.
This does not validate combined selection behavior; no further coordinate
tuning was attempted. Recheck together after PR #202's regression is fixed.

The initial probe material is archived locally under
`/tmp/meh-selection-implementation-20261004/followup/initial-probe-archive`.
The committed probe tools are under `Tools/SelectionLab/Implementation`.
Temporary app launch hooks are removed from production source. Physical
iPhone and iPad behavior, other input devices, tables, remote edits, and the
top-edge start-handle case remain unverified. These simulator and host
results do not establish physical-device interaction quality.
