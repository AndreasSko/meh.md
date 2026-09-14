# Deferred notebook dragging

This WIP preserves the unfinished native drag integration from Wave 2.
The release base retains dates, stored order, Move Up/Down, one-time sorts,
batch operations, browser undo/redo, and swipe to Trash without these hooks.

See [issue #49](https://github.com/AndreasSko/meh.md/issues/49) for the full
investigation, failed hypotheses, reproduction steps, and acceptance gaps.
This draft is not a release candidate. Do not merge it as implemented.

## Preserved implementation

The WIP restores native row identities, drag payloads, sibling drop mapping,
folder/root drop handlers, and drag-specific model/UI tests. This combined
implementation was not accepted: it contains the interaction conflicts
recorded in the issue. Keeping the old failing test is intentional.

## Reduced passing diagnostic

`passing-diagnostic.patch` captures the tested NotebookView variant relative
to the WIP's restored NotebookView. Apply it only in an isolated checkout
when deliberately reproducing that diagnostic; it is not a release fix.
The patch also removes batch controls because the diagnostic was tested
against the earlier ordering-only UI. It removes row context menus and
folder-drop targets and keeps the reorder container continuously enabled.

The reduced edit, sort, drag, re-sort, and relaunch flow passed on iOS 27
Simulator. This does not prove restored folder drops, row actions, batch
controls, or physical-device interaction. The local evidence bundle is
`meh-wave2-ui-native-full-no-note-drop-constant.xcresult`; it is not uploaded.

Use dedicated simulator data and unique preview run paths. Do not uninstall
an existing app to reset fixtures. Resume only after the design discussion
requested in #49, with a bounded test matrix and recording-based diagnosis.
