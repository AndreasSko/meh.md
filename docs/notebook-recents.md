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
