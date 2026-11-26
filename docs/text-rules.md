# Text rules

Text rules find patterns in a note and show them differently in Live
Preview, without changing the Markdown. A Bible reference like `John 3:16`
can become a link to JW Library, a line ending in `=` can show a sum of
times, and a ticket number can link to a tracker. Anyone can write their
own rule as a small JavaScript script. Rules are an experiment, so they are
off by default and live in Labs.

## Turn it on

1. **Settings › Labs › Text Rules** turns rules on for this device. It is
   off by default.
2. **Rules** lists the notebook's rules. **+** adds one:
   - **New Link Rule…**: some text or a regular expression to find, and a
     link to open for it. No code.
   - **New Script…**: a rule written in JavaScript, typed or pasted in.
     It starts empty; **a template** below it puts in a small starter
     script. An error names its line, and tapping it selects that line.
3. A rule runs in **All Notes** or in **Chosen Notes**. A rule for chosen
   notes is turned on per note in **… › Editor Display**.

### Example scripts

The app comes without rules. Two example scripts live here, ready to
paste into **New Script…**. The empty Rules page links to them. To copy
one on GitHub, open the script and tap **Copy raw file** (⧉) above the
code.

- [`bible-references.js`](text-rules/bible-references.js) links Bible
  references in German and English, like `Joh 3,16` or `Romans 8:28`, to
  the New World Translation, in JW Library or on jw.org.
- [`time-sums.js`](text-rules/time-sums.js) is the
  [time calculator](time-calculator.md) written as a rule. It starts in
  chosen notes. Turn on only one of the two in a note. Unlike the
  built-in one, it doesn't read times in tables.

Rules are notebook settings: they sync to every device that opens the
notebook, like other settings. The Labs switch stays on each device.

Each rule has a page with its options, the places its links may go, and a
**Try It** box that shows what the rule does to some sample text. Where two
rules mark the same text, the rule higher in the list wins; drag to change
the order.

## What rules can show

A rule only ever changes how text looks. The note stays as written:
copying, exporting, searching, sync and version history see the plain
Markdown, and Source mode shows it without any rule.

- `link` shows the text as a link. A tap opens it, except in the
  paragraph being edited, where a tap places the caret. On the Mac,
  Command-click opens it there too.
- `style` shows the text in a style: `muted`, `accent`, `highlight`,
  `warning`, `error`, `success`, `strong`, `emphasis`, `strike` or
  `code`.
- `insert` draws text at a position, like a time calculator result. The
  caret skips it and it can't be selected. Inside a line, the line makes
  room for it.
- `hide` hides text, like Live Preview hides `**`. The paragraph being
  edited shows it again.

Markdown links and code always stay as they are: a rule can't decorate
them.

## Writing a script

A script calls `rule()` once:

```js
rule({
  api: 1,
  name: "Ticket Links",
  description: "Links ticket numbers like ABC-123 to the tracker.",
  linksTo: ["https://tracker.example.com/"],
  block(block) {
    const decorations = [];
    for (const match of block.text.matchAll(/\b[A-Z]+-\d+\b/g)) {
      decorations.push({
        kind: "link",
        start: match.index,
        end: match.index + match[0].length,
        url: "https://tracker.example.com/browse/" + match[0],
      });
    }
    return { decorations };
  },
});
```

The editor calls `block` for each paragraph, heading, list item and
quote, and draws what it returns. Code blocks, tables and front matter are
never passed to a rule.

### Settings

Everything in `rule({ … })` except `block` is read without running the
script, so these must be written out as plain values.

- `api`: the rule API version, `1`. A newer version than the app knows
  stops the rule with a message.
- `name`: required. Shown in Settings and in Editor Display.
- `description`: shown on the rule's page.
- `example`: sample text the rule shows something for. Try It starts
  with it.
- `runsIn`: `"allNotes"` (the default) or `"chosenNotes"`, where the rule
  runs when it is added. People can change it on the rule's page.
- `linksTo`: where links may go, such as `"https://www.jw.org/"` or
  `"jwlibrary:"`. A link elsewhere is left out. Scheme and host match in
  any case; the path must match as written and can't use `.` or `..`.
  `javascript:`, `data:` and `file:` are refused.
- `input`: `"plain"` (the default) replaces Markdown markers, code and
  links with U+FFFC, so patterns don't need to know Markdown.
  `"markdown"` passes the text as written. Positions are the same either
  way.
- `blocks`: which blocks to see: `"paragraph"`, `"heading"`,
  `"listItem"`, `"quote"`. All of them by default.
- `trigger`: a regular expression a block must contain before the script
  sees it, like `"\\d"`. It saves work in long notes. Rules with a
  `start` state can't have one.
- `uses`: what `context` should include: `"today"`, `"locale"`,
  `"title"`.
- `options`: settings people can change on the rule's page; see below.
- `start`: the state the first block gets. With it, each block's
  returned `state` goes to the next block.

### What `block` gets

`block(block, state, context)`:

- `block.text`: the block's text. Offsets in decorations count UTF-16
  units in this text, like JavaScript string indices.
- `block.kind`: `paragraph`, `heading`, `listItem` or `quote`.
- `block.level`: a heading's level, or how deep a list item is.
- `block.lines`: `{ start, text }` for each line, with `start` in
  `block.text`.
- `state`: what the block before returned, for rules with a `start`.
- `context.options`: the option values, with defaults filled in.
- `context.today` (`"2026-11-26"`), `context.locale` (`"de-DE"`) and
  `context.note.title`, when listed in `uses`.

It returns `{ decorations, state }`. Both may be left out.

### Decorations

```js
{ kind: "link", start, end, url, label }
{ kind: "style", start, end, style }
{ kind: "insert", at, text, side, style, label }   // side: "after" or "before"
{ kind: "hide", start, end }
```

`label` describes a link or an insert, for example "John 3:16"; the Mac
shows it in the link's menu. An `insert` takes a short text on one line.
Its `side` matters at the edges of a line: `"after"` at the end of a line
draws after the last character, `"before"` at its start draws before the
first one. A decoration may not split a character, like an emoji. Invalid
decorations are left out, and the rule's page says why.

### Options

```js
options: {
  open: { title: "Open In", type: "choice",
          choices: { app: "JW Library", web: "jw.org" }, default: "app" },
  exact: { title: "Exact Match", type: "toggle", default: false },
  project: { title: "Project", type: "text", default: "ABC" },
},
```

The rule's page shows each option, and `context.options.open` holds the
chosen value. A value chosen before the script changed that no longer
fits, like a choice it dropped, goes back to the default.

### State

A rule with `start` reads the note in order. The time sums example
keeps the running total and the last operator in its state:

```js
start: { total: 0, sign: 0 },
block(block, state) {
  if (block.kind === "heading") return { state: { total: 0, sign: 0 } };
  // … add up the block's times, insert sums after `=` …
  return { decorations, state: { total, sign } };
},
```

State must be plain data, like numbers, text and lists, and at most 16 KB.

### Limits

A rule sees only its block. It has no network, files, timers, clock or
random numbers: `Date` and `Math.random` are gone, `context.today` gives
the date. Shared objects like `Array.prototype` are frozen after the
script loads. The editor keeps results until the text changes, so a rule
must give the same result for the same block: keep anything that carries
over in `state`, never in a variable outside `block`. JavaScript can't
freeze those variables, so this one is up to the script.

A block may take 250 ms of processor time. A rule that takes longer,
throws, or never returns stops, shows nothing, and says why on its page,
below Try It. One that stopped
responding stays off, also after the app restarts, until it is edited or
turned on again.

## How the editor runs rules

- **Reading a script.** `TextRuleCompiler.js` parses the script with
  [acorn](https://github.com/acornjs/acorn), bundled in the app, and
  reads the settings from the `rule({ … })` call without running it. It
  also adds a check at the start of every loop and function body. Once a
  call has used up its time, each check throws, so even an endless loop
  stops. JavaScriptCore has no public way to stop a running script, and
  this needs none. Line numbers stay the same, so errors point to the
  right line.
- **Running.** Each rule gets its own JavaScriptCore context and queue.
  `TextRuleRuntime.js` sets up the limits above before the script runs.
  Calls never run on the main thread, so typing never waits for a rule.
  A rule stuck inside a single built-in call, like a regular expression
  that backtracks forever, can't be interrupted; after 5 seconds the editor
  gives up on it and remembers it as stuck.
- **Blocks.** `MarkdownTextRuleBlocks` cuts the note into blocks from the
  editor's existing parse and masks markers for plain input.
- **Results.** `MarkdownTextRuleSession` keeps each block's result by its
  text, and for rules with state also by the incoming state. An edit runs
  only the blocks it changed. A rule with state runs from the first
  changed block and stops once a block's state matches an earlier run
  again. Results of the edited block disappear at once and come back when
  the rule has run, so a link never points at text that changed. The
  blocks below keep their last result meanwhile, so sums don't flicker.
- **Showing.** Results join the editor's normal presentation: links and
  fonts as layout attributes, colors as rendering attributes, hidden text
  with Live Preview's hidden markers, and inserts drawn in each layout
  fragment like time calculator results. Text inserted inside a line gets
  room from extra kerning on the character before it, or from a wider
  first-line indent at the start of a line.
- **Storage.** Rules live in the notebook catalog in flat registers,
  `textRule.<rule>.<field>` and `textRuleNote.<rule>.<note>`, so changes
  from two devices merge field by field. A value this version can't read
  leaves that rule out instead of making the catalog unreadable. Simple
  link rules are stored as data and turned into a script when they run.

## App Review

Rules are code that runs inside the app, so they follow App Review
Guidelines [2.5.2 and 4.7][guidelines]:

- The app never downloads code from us or anyone else, and ships no
  rules. Every rule is written or pasted in by the person using it. Like
  their notes, a person's rules sync only between their own devices, where
  Labs must be turned on before any rule runs.
- Scripts see only the text of the note they run in. They can't reach
  native APIs, the network, files, other notes or other apps.
- A rule can't open anything on its own. A link opens only when tapped,
  and only to a place the rule declared in `linksTo`, which its page shows.

[guidelines]: https://developer.apple.com/app-store/review/guidelines/
