# Expanded Recents

On iPhone and iPad, Recents keeps its compact list of five notes. When more
notes are available, a small grabber appears below the rows. Tap it or pull
it down to expand the card. A short pull settles back; a deliberate pull or
flick commits on release. The grabber stays at the bottom when expanded.
Tap it or pull it up to close and restore Files and its browser position.

The expanded view stays inside the iPad sidebar. In compact layouts, opening
a note returns Recents to its compact state. In a regular sidebar, selecting
a note leaves expanded Recents available beside the editor. Search, Show in
Files, selection mode, and notebook switches end expanded browsing.

On Mac, a small More button beneath the five notes unfolds Recents into a
scrollable card inside the sidebar. The editor stays visible. The fixed
Less button in the fixed bottom footer or Escape returns to Files at its
previous position. Only the notes scroll, so the footer stays visible. The
Recents menu also offers Browse All Recents / Back to Files, with
Command-Shift-R to switch between the two states. Arrow keys select notes
in the expanded native list, and context menus retain the usual note actions.

## Animation and feedback

The rounded card keeps its horizontal margins when expanded. Pulling the
footer keeps the top anchored and moves the lower edge one point per finger
point, within the browser bounds. Pulling the expanded bottom grabber upward
keeps the top anchored and contracts the lower edge at the same rate. Drag
updates explicitly disable animation. On release, a spring settles into the
expanded or compact state. Closing from older entries fades back to the
compact five rows during contraction. Text is never scaled.

A light system haptic marks the pull threshold. A slightly stronger light
impact confirms opening or closing. The system determines whether the device
supports this feedback. Ordinary scrolling does not produce haptics.

The grabber is an accessible button; pulling is optional. Its accessibility
label changes from Show all recent notes to Close Recents without visible
text. Its touch area follows Dynamic Type, and it retains accessibility focus
after settling. Reduce Motion disables finger-driven geometry and uses a
shorter settling animation.

## Data and native scrolling

The catalog already records the latest activity for each eligible note. The
full projection exposes all of these notes, with pins first. It is a list of
recent notes, not a separate event for every visit. The compact five-item
projection and local five-pin limit retain their existing behavior, including
concurrent-pin conflict handling. Trash and permanently deleted notes remain
excluded. No new catalog fields or migration are required.

Expanded previews read only a visible batch with a small prefetch margin.
Requests are capped at 64 notes; a cache retains 128 rendered excerpts. Stored
notes are decoded transiently away from the main actor. Reads do not open an
editor session or record activity, and live editor text takes precedence.
Revision changes, cancellation, and notebook switches discard stale results.

The compact UIKit table stays inside the native Files list. Vertical swipes
on recent rows scroll the browser, and horizontal swipes retain the native
pin action. Expansion and closing belong to the grabber alone.

An anchored overlay contains the grabber and unfolding history. The expanded
table preserves native swipe-to-pin, context menus, and row reuse. The overlay
is clipped to the browser viewport.

Mac uses a native SwiftUI List inside the sidebar with stable note identities
and the same bounded preview loader. Its card opens downward; the heading and
existing rows stay in place until scrolled. Reduce Motion disables this
geometry animation.
Files remains mounted beneath the card, preserving selection and scrolling.
Compact and expanded Recents share the rounded outline, width and top edge.
The expanded card stops above the sidebar's bottom edge and removes extra
list content margins. Its native selection highlight remains unobstructed.
The expanded table removes its default column gap, so note text, pins and
dividers keep the compact rows' horizontal padding.
The Mac sidebar uses thin native overlay scrollbars, including expanded
Recents and search. They appear while scrolling and fade away afterward.
They do not reserve a gutter or narrow the rows when shown. Wheel, trackpad
and keyboard scrolling remain available.
The adapter observes the native style because SwiftUI can reset it during
drawer expansion as well as when system pointing-device preferences change.
Expansion resets are corrected synchronously to prevent a wide scrollbar
from flashing during the animation.

## Row actions

In compact and expanded Recents, swipe toward the leading edge (left in
left-to-right layouts) to reveal the red Trash action. It requires a tap;
a full swipe does not trash a note. Swipe the other way to Pin or Unpin,
including the existing full-swipe shortcut. These are native UIKit actions
on iPhone and iPad, and SwiftUI List actions on Mac.

Trash flushes the open editor and uses the existing recoverable Trash and
browser Undo operation. UIKit receives success only after that operation
finishes; a busy browser or failed save reports failure. VoiceOver also
offers Move to Trash. Trashing remains available when the pin limit is full.

## Verification

Focused model tests cover full and compact ordering, pin rollback, Trash,
preview freshness, cancellation, bounded caching, and reading without opening
sessions or changing recent activity.

`RecentsExpansionUITests` uses fictional notes in a disposable loopback
workspace with the iCloud Dev build. Start the local sync server on port 9874
before running these UI tests. They cover compact browser scrolling, tap and
downward expansion, cancelled pulls, upward closing, older rows, pinning,
grabber taps, and selecting a note.
Simulator checks cannot establish the physical feel of the haptics.

`MacRecentsUITests` checks expansion, older notes, keyboard navigation,
context-menu pinning, and returning to the Files browser with fictional data.
`python3 scripts/check_mac_recents_scrollbars.py` exercises the actual Mac
drawer implementation in an offscreen native window without changing focus.
It covers repeated opening, scrolling, resizing and native style resets.
It checks the style throughout the animation and immediately after a reset.
It also compares both row edges using the actual shared note-row view.
The iPhone Recents tests also check both swipe directions, full-swipe safety,
and restoring notes from Trash after using compact or expanded Recents.
