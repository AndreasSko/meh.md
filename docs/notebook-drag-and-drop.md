# Notebook drag and drop

Files uses the existing SwiftUI list, selection, context menus, and inline
editing. Notes and folders share one drag destination.
The middle of a folder is a move target; row edges insert before or after a
sibling. Holding over a folder opens it after 650 milliseconds. The Files
header returns items to the notebook root.

## Native event delivery

The investigation in [issue #49] and [PR #50] found that the earlier SwiftUI
container approach conflicted with the full browser's other interactions.
In the new isolated iPhone experiment, both row and list `DropDelegate`
handlers received no destination callbacks even though a native lift was
visible in the recording.

SwiftUI supplies the iPhone and iPad drag preview. UIKit's collection-view
drop delegate delivers their destination events. On Mac, one AppKit gesture
recognizer starts the native dragging session and captures the actual row
preview. Ordinary clicks fail recognition below the drag threshold, so
AppKit delivers the original events for plain, Command, and Shift selection.
Control-clicks, disclosure buttons, and inline fields keep native tracking.

The same list's primary-button selection pans must wait for the source
recognizer to fail. Mac traces showed those pans beginning before the source
crossed its five-point drag threshold and canceling it. Autoscroll stops when
the pointer leaves the destination. AppKit constrains its clip bounds, so
native content insets remain part of the scrolling limits.

Mac source tracking follows Apple's TN3212 on adopting gesture recognizers.
SwiftUI source tracking in the full native list allowed selection to extend
through rows during a held drag, and subsequent disclosure clicks could stop
responding. Mac folder disclosure uses a native AppKit button with its own
target and action.
AppKit's dragging destination delivers events through a transparent list
overlay. The overlay participates only during an actual source session, so
preparing a context-menu preview does not intercept ordinary clicks.

The UIKit adapter preserves the list's existing data source and drag
delegate, and restores its previous drop delegate on removal. An accepted
drop retains its captured operation while the provider loads, independently
of SwiftUI replacing the header that installed the adapter. A newer source
token invalidates any older provider callback still waiting to complete.

One provider identity survives repeated source requests during a gesture.
Its process-local payload contains a random token. The scene retains the
notebook UUID and the selected item UUIDs with their original parents.
Note text and file paths are not transferred through the provider.

Rows and native pointer positions use window coordinates. Mac row anchors
read their current AppKit frame on every lookup, including after a native
cell moves without a SwiftUI layout callback. Weak registrations exclude
detached, hidden, and wrong-window rows. UIKit recycled rows restore their
last observed frame when they reappear. Resolution excludes geometry outside
the current list viewport. Folder expansion changes navigation state without
moving items until the user releases the drag.

## Catalog transaction

`NotebookReplica.placeItems` moves a normalized selection and generates its
sibling order under one catalog writer. It validates the captured notebook
and source parents immediately before writing. Conflicting remote source
moves, deleted items, invalid anchors, and descendant cycles reject the
operation as a whole.

The native Move sheet shares the drag destination's stored-ancestry guard.
A recovered display root with a missing parent or cycle is not offered as
a folder destination that the catalog writer would then reject.

Manual placement uses the existing parent-scoped Automerge order keys and
conditional undo receipts. A placement that changes nothing performs no
write. Selected descendants remain part of their selected ancestor's
subtree; independent selected roots retain their display order.

## Prior art

[CodeEdit] uses AppKit outline-view pasteboard writers, drop validation, and
acceptance in `ProjectNavigatorViewController+NSOutlineViewDataSource.swift`.
The inspected revision was `fa2aebd86373211c78626074b53ab75010767575`.

[CodeApp] uses native table-view drag and drop in `FileTreeView.swift`, with
folder navigation in `FileTreeViewController.swift`. The inspected revision
was `6b508f35f45b5cd8706708179400078e90f528f4`.

These projects informed the native-event approach. The browser's identity,
ordering, atomic placement, and undo behavior remain specific to meh.md.

## Reproducible interaction checks

`NotebookDragUITests` uses the iCloud Dev build and creates a new UUID-scoped
preview notebook per test. It exercises actual mouse or touch gestures,
checks the resulting hierarchy and order, and reopens notes after relaunch
to compare their literal Markdown.

The continuous-hover helper constructs one test-runner pointer path with
folder dwell points and one final release. It checks the installed XCTest
runtime signatures before using them. Those runtime APIs are confined to
the UI-test target; unavailable signatures explicitly skip that test.

The bounded `long-list` and `nested` fixtures are available only in Debug,
inside a newly created preview notebook with a validated run identifier.
They never seed a normal local or iCloud notebook.

Run the same suite with Mac, iPhone, and iPad destinations:

```sh
xcodebuild test -project meh.md.xcodeproj \
  -scheme 'meh.md iCloud Dev' -configuration Debug-iCloud \
  -destination '<platform and device>' \
  -only-testing:meh.mdUITests/NotebookDragUITests \
  -parallel-testing-enabled NO
```

For successful screen recordings, copy the generated `.xctestrun` beside
the original, preserving its `__TESTROOT__` paths, and set both attachment
lifetimes to `keepAlways`. Run that copy with `test-without-building`, then
export attachments from the result bundle. Keep recordings and screenshots
as PR attachments rather than repository files. Label simulator captures
separately from physical-device evidence.

[issue #49]: https://github.com/AndreasSko/meh.md/issues/49
[PR #50]: https://github.com/AndreasSko/meh.md/pull/50
[CodeEdit]: https://github.com/CodeEditApp/CodeEdit
[CodeApp]: https://github.com/thebaselab/codeapp
