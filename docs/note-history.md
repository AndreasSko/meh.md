# Version history

History lets you go back to any earlier state of a note and see what each
edit changed. It should feel calm: the note stays readable, and the controls
stay small at the bottom of the page.

## The timeline

A rail at the bottom shows the note's past from left to right, ending in a
dot for the current text. Each tick is one edit session: a burst of typing
counts once, like the overview stops the history index already groups.
Taller ticks mean bigger edits, on a log scale, so a typo and a pasted page
both stay readable. Gaps between days grow with the quiet days between them.

The selected day spreads out so its sessions are easy to pick. Other days
fold into small clusters. A busy day spreads only to a set width; past that,
its ticks sit closer together. The selected tick stays in the middle under a
small `•_•` handle, and the rail moves underneath it, like the scrubber in
Photos. Drag right for older versions, or tap a tick. On a Mac, hovering a
tick shows its time and size, and the arrow keys step through sessions.

## Every saved state

Sessions hide the single keystrokes inside them. To reach those, the rail
switches to one tick per saved state:

- On iPhone and iPad, slide your finger up while dragging the rail.
- On a Mac, pinch the rail or press ⌘+, and ⌘− to go back. ⌥← and ⌥→ step
  through single states without zooming.

A tip explains this once. A state picked inside a session stays a single
state after the rail folds back: the caption and heading show its time to
the second and its own size.

## What changed

Each version is compared with the one before it at the rail's current level:
the previous session, or the previous saved state. Changing the level
compares again. The text stays clean. A highlighter line in the margin marks
changed lines, and a small ring marks where lines were removed; tapping or
clicking the ring shows the removed text. An edited line gets only the
highlighter line, but when an edit leaves fewer lines than it replaced, a
ring keeps the old text. Marks on the right edge show where changes are in
the whole note. When some changes are off screen, a pill steps to them.

VoiceOver reads the caption and how many places changed or lost text on the
rail. An action there reads the removed text.

## Cost

Notes store and sync nothing new. The only new data is TipKit's record of
the tip, which stays on the device. The history index already computes the
Automerge changes of every version, and now also counts the characters each
one added and removed. On the fixture in
[History performance](history-performance.md), the full index took 5.009 s
against 4.991 s before (mean of three runs each), within run-to-run noise.

The comparison runs only for the selected version, on the history reader. It
splits lines at line feeds, so CRLF notes compare line by line too. It skips
the lines both texts share at the start and end, then diffs the rest.
A rewrite too large to diff quickly marks the rewritten lines as changed
instead. Each layout fragment draws its own margin marks, so only visible
text pays for them.
