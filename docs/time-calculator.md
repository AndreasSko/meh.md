# Time calculator

Notes often hold small time sums: a travel day, a list of tasks, the hours
worked this week. The time calculator adds them up inside the note, the way
the owner's earlier Doodleator app did, without changing the Markdown. It is
an experiment, so it is off by default and only runs in notes where it was
turned on.

## Turn it on

1. **Settings > Labs > Time Calculator** turns the feature on for this
   device. It is off by default. The Labs screen explains it with a short
   example.
2. **Note Actions > Editor Display > Time Calculator** turns it on for one
   note. This choice syncs, so the note calculates on every device where
   Labs has the feature on. The menu item only shows while the Labs setting
   is on.

Turning the Labs setting off hides all results but keeps each note's choice.

## Write a sum

End a line with `=` and Live Preview shows the result after it:

```markdown
Drive to airport 50m
Security and waiting 1h 30m
Flight 2h 55m
Time zone -1h

Travel day =
```

The last line shows `Travel day = 4h 15m`.

- **What counts:** every line above, up to the previous `=` line or heading,
  and the `=` line itself, so `2h + 30m =` works on one line. Blank lines do
  not stop a sum.
- **Values:** a number followed by `d`, `h`, `m` or `s`, with or without a
  space: `45m`, `1.5h`, `1,5h`, `2 d`. Words that only start with a unit,
  like `5min` or `3 days`, are not read.
- **Plus and minus:** `+` or `-` applies to the value right after it, even
  when that value is on the next line. In `1m`, `-5m +`, `1m` the result is
  `-3m`. Parts of one time share the sign: `-1h 30m` subtracts 90 minutes.
  Operators need no spaces: `+7m-1h` subtracts the hour. A `-` inside a
  word, as in `Mon-Fri`, is not an operator.
- **Not read:** list markers (`- `, `+ `, `* `), inline code, code blocks,
  and links. `- 5m` is a list item worth plus five minutes; write `- -5m` to
  subtract inside a list.
- **Results** use the largest units first and leave out zero parts:
  `1d 2h 5m`, `-3m`, `0m`.

A line that ends in `==`, such as a `==highlight==` or a heading underline,
does not ask for a sum.

## Nothing is saved

The result is calculated each time the line is drawn. It is never written
into the note, so it cannot go out of date, and two devices never edit the
same total at the same time. The Markdown copies, backups and version
history contain `Travel day =` without the result.

## Source mode and Live Preview

Source mode shows the text as written, without results, like it shows tables
as pipes. Live Preview draws the result after the `=` on every line,
including the one being edited, so it updates while typing. The result is
drawn, not text: the caret cannot enter it, it is not part of a selection,
and VoiceOver does not read it yet.

## Markdown compatibility

A line that ends in `=` after other text has no meaning in Markdown, so the
note looks the same in any other app, just without results.

A line with only `=` also works in a calculator note, but other apps read it
as a heading underline: the whole paragraph directly above it becomes a
level-1 heading ([CommonMark setext headings][setext]). The text stays, only
its style changes. Writing a label before the `=` avoids that. meh.md's
editor does not recognize underline headings yet; see #272. Once it does, a
calculator note should keep treating `=` lines as sums.

[setext]: https://spec.commonmark.org/0.31.2/#setext-headings

## Implementation

- **Sums:** `MarkdownTimeCalculator` reads the values and operators from the
  note text. It skips list markers, code and links and ends a sum at
  headings, using the editor's existing syntax parse.
- **Drawing:** the result is drawn after the `=` next to the History margin
  marks: in each layout fragment on iPhone and iPad, and in the text view's
  background on the Mac. Nothing touches the text storage, so selection,
  input and Undo are unaffected. After every refresh, only lines whose
  result changed are redrawn.
- **Settings:** the Labs switch is a device-local `@AppStorage` value. The
  per-note choice is a `timeCalculator.<note ID>` key in the notebook
  catalog, like snippet sources, so choices from different devices merge.
  Older app versions ignore the key.
- **Cost:** notes without the calculator do no work. In calculator notes,
  each refresh scans the note text once.
