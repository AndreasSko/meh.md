# Version history

History lets you go back to any earlier state of a note and see what each
edit changed. It should feel calm: the note stays readable, and the controls
stay small at the bottom of the page.

## The timeline

A rail at the bottom shows the note's past from left to right, ending in a
dot for the current text. Each tick is one edit session: what you wrote
while the note stayed open, without a pause longer than three minutes.
Reopening the note, an edit from another device or a restore starts a new
session. Taller ticks mean bigger edits, on a log scale, so a
typo and a pasted page both stay readable. A session's size is what it
changed overall, so text typed and deleted again does not count. Gaps
between days grow with the quiet days between them.

The selected day spreads out so its sessions are easy to pick. Other days
fold into small clusters. A busy day spreads only to a set width; past that,
its ticks sit closer together. The selected tick stays in the middle under a
small `•_•` handle, and the rail moves underneath it, like the scrubber in
Photos. Drag right for older versions, or tap a tick. On a Mac, hovering a
tick shows its time and size, and the arrow keys step through sessions.

## Steps inside a session

Sessions hide the steps inside them: what you typed between pauses longer
than five seconds. To reach those, the rail switches to one tick per step.
History loads steps for the selected session and a few sessions around it
while you browse, so they are usually ready when you switch. A session
whose steps are still loading shows as one tick until they arrive.

- On iPhone and iPad, slide your finger up while dragging the rail.
- On a Mac, pinch the rail or press ⌘+, and ⌘− to go back. ⌥← and ⌥→ step
  through steps without zooming.

A tip explains this once. A step picked inside a session stays selected
after the rail folds back: the caption and heading show its time to the
second and its own size.

## What changed

Each version is compared with the one before it at the rail's current level:
the previous session, or the previous step. Changing the level
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
the tip, which stays on the device. The history index counts the characters
each session and each loaded state added and removed from the Automerge
changes it already computes. See
[History performance](history-performance.md) for how sessions keep long
notes fast.

The comparison runs only for the selected version, on the history reader. It
splits lines at line feeds, so CRLF notes compare line by line too. It skips
the lines both texts share at the start and end, then diffs the rest.
A rewrite too large to diff quickly marks the rewritten lines as changed
instead. Each layout fragment draws its own margin marks, so only visible
text pays for them.
