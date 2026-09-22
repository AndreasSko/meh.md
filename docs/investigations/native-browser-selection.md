# Native selection and Move sheet

Date: 2026-09-22. Branch: `codex/native-file-browser`.
Work began in an isolated worktree and moved to the main checkout at the
user's request. The original local drag checkpoint was `a81b422`.

The user authorized finishing native selection and the destination sheet while
explicitly deferring drag. No new drag investigation or platform adapter was
started. The failed diagnostic sources now live under `drag-gate/`, outside
the application and test targets. Those local diagnostics and the historical
agent handoff are intentionally excluded from the release PR.

## Implementation

- One List supplies Files selection, with stable domain UUID tags. Recents has
  separate presentation identity and cannot join Files bulk operations.
- The touch selection toolbar replaces Search/New Note with Move, Trash,
  count, and secondary selection actions. Done exits selection. Native
  controls render the toolbar material and standard selection indicators.
- The expanded Files outline defines Select All, including off-screen rows.
  Collapsed selections remain in the scene-local selection; Reveal Selection
  expands their ancestors. Catalog removals prune genuinely unavailable IDs.
- List primary actions separate iOS/iPadOS activation from modifier selection.
  On Mac, a simultaneous plain-click activation opens the note while List
  retains native Command/Shift selection. Binding updates never open notes,
  avoiding editor jumps during programmatic hierarchy changes.
- Browser-scoped key handlers provide Command-A, Command-Shift-M (Move), and
  Command-Delete (Trash). Inline naming and the separate editor retain their
  own text command handling. No browser command changes editor Undo.
- Native item context menus use the selected set on selected rows and only
  the target on unselected rows. Bulk context actions include hidden selected
  descendants. Undo Move / Redo Move live in the browser menu.
- The shared Move sheet uses NavigationStack and child-folder Lists, an
  explicit path, source name/count, Up one level, and Move Here. It starts
  at the effective sources' common parent, or root for mixed-parent groups.
- Submission keeps the sheet open, blocks duplicate submission/dismissal,
  and shows inline errors for retry. Source eligibility, notebook identity,
  and destination are revalidated after flushing the editor. Existing core
  atomic mutation, ancestry checks, normalization, and Move undo are reused.
- A current-parent no-op does not alter order or undo history. Successful
  moves reveal destination ancestors and preserve the editor session.
- Native context actions, rename, sorting, and swipe-to-Trash remain. Move
  Up/Down and Undo Trash remain absent. Persistence/schema/Markdown are
  unchanged.

The primary-action semantics were checked against Apple's documentation for
`contextMenu(forSelectionType:menu:primaryAction:)`.

## Verification

Both iOS Simulator and macOS Local builds passed. A focused Swift package run
passed 53 tests (17 app-model and 36 core tests), covering selection,
navigation, ordering, atomic batch operations, source fidelity, and undo.

The dedicated iPhone 17 / iOS 27 simulator was reused with fresh fictional
preview notebooks and automatic sync disabled. No existing app data was reset
or uninstalled. Four UI scenarios passed across two runs:

1. Batch selection, Trash, restoration, and exact edited source preservation.
2. One-time sorting, absence of removed controls, relaunch order, and exact
   source preservation, including actual iOS editor input.
3. Native swipe-to-Trash and restoration.
4. Root-to-root no-op with unchanged order/no undo, hierarchical destination
   navigation, cancellation preserving selection, confirmed batch move,
   destination reveal, and Undo Move restoring root order.

The initial Move test reached the correct destination but failed because its
path query matched both Label text and icon. The query was narrowed to
StaticText, then only the affected Move case was rerun successfully.

Selection and Move sheet frames were extracted unchanged from the test video
and visually inspected. They show native selection circles, visible toolbar
actions/count, and the destination sheet with path and explicit confirmation.
Screenshots are local evidence, not repository files.

Local artifacts (under `/private/tmp`):

- `meh-native-selection-ios.log`: successful iOS build.
- `meh-native-selection-mac.log`: successful macOS build.
- `meh-native-selection-core-tests.log`: 53 passing focused tests.
- `meh-native-selection-ui-1.xcresult`: three UI passes plus the path-query
  failure; matching log and exported attachments are available.
- `meh-native-selection-move-ui-2.xcresult`: passing expanded Move scenario.
- `meh-native-selection.png` and `meh-native-move-sheet.png`: inspected frames.
- `meh-native-selection-mac-ui-2.xcresult`: Mac automation infrastructure
  failure before tests connected; not an app interaction result.

## Remaining verification limits

The focused Mac plain/Command/Shift selection and keyboard-focus test was
compiled, but its runner hung before establishing connection. The environment
investigation was stopped rather than extending the task into automation
repair. Mac pointer/keyboard acceptance is therefore still pending.

The user subsequently accepted the final fixed sheet. iPad keyboard/trackpad,
narrow iPad windows, Dynamic Type,
VoiceOver, and Reduce Motion were not interactively checked. The error/retry
UI and remote-invalidated destination path were code-reviewed; no simulator
failure injection was added. Core tests cover invalid atomic operations.
Collapsed-selection retention and context targeting are implemented and
reviewed but do not yet have a dedicated platform interaction test.

PR preparation bumps the app to 0.1.11. Drag remains deferred under #49.

## Approved layout refinement

The user reviewed the first iPhone capture and approved moving Files actions
into the top-right browser menu. Select Items is its first action; sorting,
New Folder, Move undo/redo, and existing app actions remain available there.

Recents and Files now share native section headers with identical insets and
compact section spacing. The detached Files ellipsis is removed. Selection
uses Select All / Deselect All at the leading edge, a centered count, and Done
at the trailing edge. The large app title is suppressed while selecting.
The bottom toolbar contains only Move and Trash, using system toolbar items
and spacing. The count reveals any selected rows hidden by collapsed folders.
Normal Search/New Note controls return after Done. Sync status remains in
normal browsing and is omitted from the selection bar to leave room for its
controls.

The narrower folder-disclosure gutter keeps note/folder icon and text columns
consistent. No persistence, drag, or Move-sheet behavior changed in this pass.

Refinement verification: final iOS and macOS builds passed. The focused iPhone
Move test passed on the final layout, including the new top-menu entry,
Select All / Deselect All, disabled Move with no selection, Done restoring
normal controls, no-op/cancel/commit, and Undo. An initial count lookup was
updated from StaticText to Button, reflecting the count's reveal action.

Final browsing and selection captures were visually inspected. Both headers
share the same margins; the detached menu and excess gap are gone. Explicit
system secondary colors avoid applying secondary emphasis twice in section
headers. UIKit supplies the bottom toolbar's compact icon presentation; Move
and Trash retain their accessibility labels.

Final evidence under `/private/tmp`:

- `meh-browser-layout-ui-final.xcresult` and its matching log/attachments.
- `meh-browser-layout-mac-final.log`.
- `meh-browser-browsing-final.png` and `meh-browser-selection-final.png`.

Mac UI automation and physical-device limitations above still apply. No core
or model tests were repeated for this presentation-only refinement.

The user chose a folder-with-arrow Move control. The correct SF Symbol is
`arrow.forward.folder`, rendered directly as an Image with “Move” retained
for accessibility. The earlier `folder.badge.arrow.forward` name does not
exist; it compiled but left a blank button on the user's iPhone.

The Move Here confirmation now keeps its text throughout submission. Its
previous Text-to-ProgressView swap changed the native toolbar button's size
and clipped its label on the user's iPhone. Progress appears beside the
source summary instead; confirmation remains disabled until completion.

The existing batch-move UI test checks the confirmation's label, disabled
state, and unchanged width/height during submission. An explicit DEBUG-only
delay flag, restricted to isolated preview notebooks, makes that transient
state observable without delaying normal use or release builds.

### Shared toolbar experiment

The user reported a distracting toolbar refresh when entering subfolders.
Two bounded attempts to share the sheet's actions failed on iPhone Simulator:

- A toolbar on the NavigationStack itself omitted both actions at the root.
- A toolbar on the root content displayed the actions there, but omitted
  them after navigating into a folder.

The existing batch-move UI test detected both regressions. Results are in
`/private/tmp/meh-move-shared-toolbar.xcresult` and
`/private/tmp/meh-move-root-toolbar.xcresult`. Both experiments were reverted;
the working per-destination toolbar was restored at that point.

The user then approved a fixed sheet. It now uses a single navigation root;
folder buttons update the local path and list without pushing a destination.
Up one level appears in Current location below the full path when browsing
inside a folder. Cancel and Move Here stay in the same toolbar. Submission
still targets the current path, with existing validation and saving feedback.

Verification: the focused iPhone Simulator batch-move test passed with
root-to-folder, Up, and folder-again checks. Cancel and Move Here remain
enabled and retain identical frames across those states. Cancel, no-op,
submission sizing/progress, actual move, and undo also passed. macOS build
passed. Evidence: `/private/tmp/meh-move-fixed-sheet.xcresult`,
`/private/tmp/meh-move-fixed-sheet.png`, and
`/private/tmp/meh-move-fixed-sheet-mac.log`. The user subsequently accepted
this version before requesting the PR.
