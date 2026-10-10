# Test foundation

This first migration replaces repeated UI preparation with fictional,
isolated notebooks. A scenario owns a fresh notebook and editor preferences;
relaunching that same scenario retains its UUIDs and edits. Seeding uses the
normal replica APIs before the app publishes its catalog. It does not replace
the native gestures, editing commands, save boundary, or persistence checks.

## Coverage contract

| Goal | PR lanes | Status |
| --- | --- | --- |
| Writing, formatting, undo and durability | All UI | Replaces persistence |
| Reorder, undo, sort, folder edges and reopen | All UI | One journey |
| Subtree safety, cancellation and recovery | All UI | One journey |
| Long-list autoscroll and relaunch | All UI | One journey |
| Batch drag, identity and saved source | iPhone/iPad | Mac deferred |
| Source cold focus, typing and native Return | iPhone UI | One journey |
| Preview cold focus in a long note | iPhone UI | One journey |
| Preview typing and list Return | iPhone UI | One journey |
| Large History dismissal, navigation and reopen | iPhone UI | One journey |
| History restore as a new note, original preserved | iPhone UI | One journey |
| Geometry, selection and literal edit semantics | Native | 47 strict guards |
| Convergence and loopback transport | Sync | Retained |
| Release compilation and performance budgets | Existing | Retained |

Seeded setup removes creation of notes/folders unrelated to the goal, while
preserving native gesture, UUID, hierarchy, order and relaunch assertions.
The reorder/edge journey seeds its unrelated nested-folder setup; the
selected-note journey creates its destination folder through the UI. Four
drag journeys cover reorder/undo/sort, subtree safety/recovery, autoscroll and
batch selection. They retain exact
identity, source, hierarchy and relaunch checks. Relaunched subtree disclosure
checks prove each parent link, including a restored child note. Swipe-trash
and restore remain in the subtree recovery journey. Duplicate nested moves
and reverse-sort journeys are retired. Autoscroll stops scrolling when its
stable witness is visible, and avoids whole-app hierarchy dumps on successful
runs.
The writing case preserves the original UTF-8 prefix and save-status checks
from the old persistence case, and adds native formatting/undo.

The UI plans select 10 iPhone cases, 5 on iPad and 4 on Mac: 19
executions instead of the original 38 or the intermediate seeded suite's 41.
Eleven obsolete UI methods are removed from the iOS test source inventory.
Keyboard journeys assert visible insertion and exact source, rather than
one-point geometry differences, repeated Return offsets or heading placement.
Cold-focus journeys observe the tapped paragraph above the keyboard before
the first key and afterward. Distinct inserted words identify each new line.
They do not depend on blue caret pixels or the caret's blink phase.

The 47 strict native guards check selection and edit semantics, plus explicitly
arranged viewport and caret geometry. Actual UI cold taps cover automatic
keyboard focus. Fresh-editor restoration, native insets, marked-text deferral
and restoration completion remain covered. Three failing native methods are
retired: the iOS Find fixture, same-editor capture/restore and the initial
preview anchor before attachment. Their specific outcomes are no longer
directly checked. The retired UI journey also removes held-hover folder
opening, continuous deep-folder dragging and Files-root return coverage.
The Mac batch-drag scenario is excluded from the Mac plan after a native drag
reached the folder center but left the selected notes at root. The method
remains selected on iPhone and iPad. [Issue #213][mac-batch-drag] records the
failure and criteria for restoring Mac coverage. No app behavior fix or
weaker hierarchy assertion is included here.

[mac-batch-drag]: https://github.com/AndreasSko/meh.md/issues/213

Settled UI checks do not guarantee every transient animation frame. Cold-focus
insertion and visibility checks do not establish that the viewport stayed
stable; a large jump can still leave the inserted text visible. Broad saved
position and native viewport checks remain, but the removed same-editor and
initial-preview guarantees are not equivalent to fresh-editor restoration.

History journeys assert preserved or restored content. Mac History UI, slider
movement, Overview/More Detail and dated-version menus are not exercised by
these plans. Title placement and button-height checks are deliberately
retired. Cheap native tests
retain editing and selection semantics without repeating a complete UI launch.

These plans are a focused PR contract, not a claim that every legacy UI test
now runs in CI.
Creation/rename, headings, tables, search, templates, snippets, imports,
Recents, browser scrolling and ordered cross-device UI sync remain outside
these plans. Their existing tests are retained for later goal-by-goal review.
Native table commands do not prove physical keyboard delivery or gestures.
The live iCloud development plan remains separate.

## Execution and evidence

The `meh.md CI` scheme uses Debug-iCloud. Each lane builds its platform
plan once, enumerates that compiled selection, and runs the unmodified native
`.xctestrun` without rebuilding. Test selection, ordering, parallelism, capture
and per-test timeouts live in the Xcode plans. A missing or disabled selector
fails before execution. No source-text parser defines coverage.

A small result checker rejects missing, extra, duplicate, skipped or ultimately
failed selected UI cases and unexpected devices. Xcode retries a failed UI test
once in a fresh process; retries are reported visibly. This applies to UI
tests, not performance measurements. A successful retry passes with a warning;
a test that fails both attempts remains red. Xcode can repeat passing cases
in the same batch and retain their earlier pass if an extra attempt fails.
The native parent result is authoritative; warnings show every repeated case
and its attempt results, including a failed extra attempt. Videos remain only
for failures. A missing video cannot fail a functional check. Logs stream into
the Actions job and are also saved. Artifacts contain raw results, failure
attachments, the native test run, source revision/tree, toolchain and stage
times. There are no whole-tree, product or artifact hash passes or plist
selection rewrites.

Boot, build, discovery, execution and export retain bounded process watchdogs
and cleanup. These stop stuck tools, not performance regressions. The native
plans retain the previous effective 30-minute UI case allowance, capped at
45 minutes; moving policy into plans does not tighten these watchdogs. The
separate 180-minute job watchdog provides export and cleanup headroom.
Timeouts or cancellation kill the owned process group
before cleanup. Only the lane's simulator is removed. Mac UI execution requires
a hosted Actions guest because it drives the desktop. Raw XCTest failures and
recordings remain available without automatic system hang-diagnostic capture.

The native suite runs current code once against a checked-in inventory of 244
approved methods from source `9fff517` and CI run `38024061478`. All recorded
methods, including the 47 strict guards, must pass except the one existing
opt-in performance skip. Additional methods must pass; new skips, duplicates
and missing retained methods fail the gate. An inventory update is an explicit
reviewed coverage change. The old revision is not rebuilt or executed.

Performance checks run current code against recorded known-good measurements
and fixed coarse budgets. No historical revision is rebuilt or benchmarked in
ordinary PR checks. Manual diagnostics may compare old code deliberately.
Release builds remain separate because they validate another configuration.
See [editor-performance.md](editor-performance.md) for the baseline provenance
and latency policy. These checks do not establish physical-device behavior or
live CloudKit coverage.

## Adding the next goal

1. State a user outcome and its required platform differences.
2. Put nonessential setup into a typed fictional fixture, keeping the action
   under test in the UI. Give each test its own preview run identifier.
3. Assert exact source and known UUID across a real boundary when durability
   is the goal. Wait for observable readiness rather than fixed sleeps.
4. Add the scenario to the native plan and verify its compiled discovery,
   result and retained failure evidence. Keep it independently executable.
5. Account for each assertion when retiring a legacy case. Obtain execution
   evidence for a replacement, or document the specific coverage deliberately
   given up when a case is removed without replacement.

Several assertions may share one scenario when they establish the same goal.
Unrelated journeys stay separate so an early failure cannot hide another
feature. Do not bypass cold layout, autoscroll, native undo or startup
conditions just to shorten a regression test.
