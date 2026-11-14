# Readwise sync

Status: 2026-11-14. Built as a Labs experiment.

Readwise collects highlights from books, articles, tweets and podcasts.
This feature keeps those highlights as ordinary notes in the notebook and
keeps them up to date. You can move, rename and edit the notes like any
other note, and later Readwise changes still arrive. It starts as a Labs
experiment. Readwise is the first integration; the same foundation should
later take others, such as JW Library backups.

Nothing is written back to Readwise. Readwise's own Obsidian export is
one-way as well.

In code and in this document, a connection between the notebook and an
outside service is an **integration**. Readwise is the first one. The word
is not used for system features such as Shortcuts or widgets.

## What you see

1. **Settings > Labs > Readwise** turns the feature on for this device and
   shows **Settings > Readwise**, a page of its own.
2. Setup asks for a Readwise access token, with a link to the page where
   Readwise shows it, and a folder. Once the token is checked, the button
   says what will be imported, such as "Import 2 Books and 1 Article", and
   the first sync shows its progress.
3. Each Readwise category gets a subfolder: Books, Articles, Tweets,
   Podcasts. A folder is created when its first item arrives, and created
   again if you deleted it. Readwise's own curated highlights
   (`supplementals`) are hidden unless a setting shows them.
4. One device syncs with Readwise: when it opens, and every few hours while
   it stays open. The device that set up Readwise starts as that device.

The settings page shows which device syncs, when it last synced, the
folder and how many notes it keeps up to date. On the syncing device it
offers **Sync Now**. Every other device offers **Sync on This iPad**,
which makes it the syncing device and syncs immediately. Only you
change the syncing device. If it has not synced for a week, because it
was lost, reset or not opened, Settings › Readwise says so on every
device; if it needs an app update to keep syncing, the other devices say
that too. Devices are named by type (iPhone, iPad, Mac); "this device"
marks the one you are using.

The settings page also shows any error, **Highlight Links** (block IDs),
the supplementals switch, **Edit Template**, **Bring Back Deleted Notes**,
and **Disconnect**, which asks first. Disconnecting keeps every note as an
ordinary note.

In an imported note, **Note Actions > From Readwise** offers **Open in
Readwise**, **Sync Now** and **Reset to Readwise Version…**, which asks
first, then moves the note to Trash and imports it again. Both are
unavailable while a sync runs. A second copy of a note, left by an overlap
between two devices, is marked as one.

The editor marks the text Readwise owns with a faint line in the margin,
and a hint above the first imported note you open says to write between
highlights; it stays closed once you close it. In live preview a block ID
is small and dimmed at the end of its line, and the blank lines around it
shrink, so a highlight, its ID and the line under it read as one block.
The Markdown stays the same.

The setup is shared through the notebook, so every device sees the same
folder and settings. The token is kept in iCloud Keychain, so any device
can become the syncing device without a second setup. The Labs switch is
per device: a device with it off still receives the notes through iCloud
and never contacts Readwise.

## How a note looks

One note per book or article. The default layout:

```markdown
---
author: Alan Kay
url: https://example.com/article
tags: [computing]
---

> The best way to predict the future is to invent it.

^rw-512345

*Kay at Xerox PARC.* · #history · [p. 42](https://readwise.io/…)
```

The note's name is the title, so the layout has no title heading, and
the folder already says the category. Highlights appear in book order.
Each one is a blockquote followed by one line with its note in italics,
its tags as hashtags, and a link back to Readwise named after where the
highlight is: a page (`p. 42`), a Kindle location (`Loc. 1234`), a time
in a podcast (`12:05`), or `↗` when Readwise gives no such place.
Discarded highlights are left out. Reader's full document text is not
included for now.

The `^rw-512345` after a quote is a block ID, on its own line as Obsidian
wants it for quotes. Another note can
link to that highlight with `[[The Early History of Smalltalk#^rw-512345]]`.
Block IDs come from Obsidian and are not standard Markdown; no standard
exists for addressing part of a note. meh.md already follows these links,
and Obsidian-style tools understand them, so they fit the Wikilinks the
app already uses. Other apps show the ID as plain text, so **Highlight
Links** turns block IDs off. Sync does not depend on them.

## Who owns what

Readwise owns the highlights. You own everything around them.

| You do | Readwise does | Result |
|---|---|---|
| Add headings or comments between highlights | Adds a highlight | Both stay |
| Delete a highlight | Nothing | It stays deleted |
| Delete a highlight | Changes it | It comes back with the new text |
| Edit inside a highlight | Nothing | Your edit stays |
| Edit inside a highlight | Changes it | Readwise's version replaces it |
| Add text right before or after a highlight | Changes it | Your text stays |
| Move or rename the note | Anything | The note keeps updating |

An edit removed this way stays in the note's version history. Text
outside Readwise's blocks is never deleted. The header, including the
front matter, is one of those blocks: a line you add inside the front
matter is replaced when Readwise changes the book's details. Keeping
your own keys there would need ownership per key, which is left for
later. Switching the syncing device needs nothing else; see [Several
devices](#several-devices).

- **Readwise renames a book or changes its category.** The note follows,
  unless you renamed or moved it yourself since the last import. Your
  choice wins.
- **Readwise deletes a highlight.** It is removed from the note.
- **Readwise deletes a book.** The note stays, is marked as removed from
  Readwise, and stops updating.
- **You delete a note.** It does not come back. **Bring Back Deleted
  Notes** imports deleted ones again, like the "Resync deleted files"
  option of Readwise's Obsidian export.

Readwise's own export cannot do this. It overwrites a file only while it
is unedited and otherwise appends new highlights at the end. Edits to
existing highlights never arrive, and a renamed file is created again.
The notebook can do better because every note keeps its full history.

## Templates

By default the built-in layout is used. **Edit Template** first creates a
note called Readwise Template in the Readwise folder, fills it with the
built-in layout, selects it as the template and opens it. Because it
matches the built-in layout, nothing changes until you edit it.

Templates use Jinja, the language of Readwise's own Obsidian templates,
with Readwise's variable names. Most people can paste the template they
already use with Readwise:

```markdown
# {{ title }}

- Author: {{ author }}

{% for highlight in highlights %}
> {{ highlight_text }}
{% if highlight_note %}
Note: {{ highlight_note }}
{% endif %}
{% endfor %}
```

Inside the loop, highlight variables keep their Readwise names, so a
highlight template copied from Readwise works unchanged. The supported
part of Jinja is what Readwise's templates use: variables, `if`, `elif`,
`for`, `set`, whitespace control, and the filters `trim`, `default`,
`join` and `date`. `date` takes Readwise's format letters, as in
`date('F j, Y')`. The built-in layout also uses three additions:
`highlight_location_label` (such as `p. 42`), `emphasis`, which puts each
line in italics, and `hashtag`, which turns a tag into one word.

- **Edits apply on their own.** A template change applies once you stop
  editing: when you leave the note, or after about a minute without
  typing. There is no Apply button. The update runs in the background, in
  batches, with one history entry per note.
- **Broken templates keep the last good version.** A template is used only
  after it renders a sample book without errors. An unknown variable or
  field, a filter used wrongly or an unclosed block is shown in Settings >
  Readwise instead. Loops nest at most three deep, and a template that
  does too much work for one book stops with an error, so it cannot freeze
  the app.
- **No "now".** Variables such as the current date would render
  differently on each device. Templates offer Readwise's dates only,
  formatted in one stored time zone.
- **Typing `{{`** in the template note suggests the variables, as it does
  in note templates. The template note is left out of links, backlinks
  and Readwise sync itself.
- **Reset to Default** replaces the template text with the current
  built-in layout, as an ordinary edit.
- **A trashed template** is still used, because trashed notes keep their
  text. Only a permanently deleted template falls back to the built-in
  layout.

A customized template does not receive later improvements to the built-in
layout; Reset to Default does.

## How it works

The notebook already has most of what this needs. The new parts are a
record of which note belongs to which Readwise item, and a way to tell
Readwise's text apart from yours inside a note, on every device.

### Notes stay linked wherever they move

Every note has a stable ID in the catalog, separate from its name and
folder (see the [notebook core contract](notebook-core-contract.md)). The
link from a Readwise book to its note uses that ID, so moving or renaming
the note changes nothing. Readwise's Obsidian export, by contrast, maps
file paths to books and follows renames with file events.

### What an integration delivers

An integration hands the engine a list of items. Each has a stable key
(the Readwise book ID), a folder (the subfolder it belongs in, such as
Books), a title, dates, a "removed" flag, and its rendered text split into
blocks. A block is the note header or one highlight, each with its own
key. Rendering, including templates, happens before the engine; the
engine only compares blocks.

With a template, each pass of the `for` loop is one highlight block, the
text before the loop is the header block and the text after it a footer
block at the end, so the note keeps the template's order. A template that
prints highlights outside a top-level loop makes the whole note one
block.

### Which text belongs to Readwise

Automerge can attach a **mark** to a span of text: a name and a value
stored with the characters, the way rich-text editors store bold or a
link (`Document.mark(obj:start:end:expand:name:value:)`). Each block is
written as marked text: name `integration`, value the block key plus an
instance ID that is new for every insertion.

- **Edits inside a block join it.** Text typed in the middle of a
  highlight carries its mark, so Readwise's next version replaces it.
- **Text at the edges stays yours.** The marks use `ExpandMark.none`, so
  text typed directly before or after a block is not marked. The blank
  lines between blocks are not marked either, so a heading typed there is
  yours. A highlight's span runs from its quote to its last line, the one
  with the link back to Readwise, so text typed at the end of the quote
  still belongs to it.
- **Marks travel with the text.** They are part of the document and its
  history, survive every merge, and never appear in exported Markdown,
  Markdown copies or backups.

Three details make copies from two devices stay apart. The spike found
each of them (`IntegrationMarksBehaviorTests`):

- **Each highlight brings its own blank line.** Automerge anchors the
  start of a mark to the character in front of it. When two devices
  insert at the same place, their copies bled into each other in about
  half the runs. With a blank line inserted in front of each copy, as
  part of the same insertion, they stayed apart in every run.
- **That blank line has a mark of its own, named after the instance.**
  Removing a copy takes its own blank line only when it is still directly
  in front of it. One shared mark name did not work: only one value of a
  name shows at a position, and a neighbour's mark can spread over it.
  Line breaks directly in front of a new highlight are swapped for its
  blank line, so the spacing you see stays the same.
- **The header is edited in place at the top.** Frontmatter must start on
  the first line, so the header never gets a blank line in front of it.

Each note also keeps a map from block key to the instance and a hash of
the text Readwise last wrote for it, as one value per block, under an
`integration` key in the note document. Only the device that creates a
note creates the map; its entries merge like other Automerge registers.

### Updates

For each block, the engine compares the new text's hash with the map:

| Map says | Note has | Update |
|---|---|---|
| Same hash | Anything | Nothing; your edits stay |
| Different hash | The marked span | Replace the span with the new text |
| Different hash | No span (you deleted it) | Insert the new text there |
| No entry | Nothing | Insert the new block in its place |
| Entry, but Readwise removed the block | The marked span | Delete the span |

"In its place" means directly after the span of the block that comes
before it in Readwise's order, or after the header. An empty block is not
written, and a block that becomes empty is removed. The text, the marks
and the map change together in one Automerge change, so a crash cannot
leave them out of step.

Text that was cut and pasted, or brought back with Undo, carries no mark,
because it is inserted again. Unmarked text is always yours, even if it
matches a highlight word for word, so the engine never claims it. If
Readwise later changes that highlight, the note shows your copy and the
new version.

Restore and the editor's rare whole-text save after a remote change
replace the text in one go. In a linked note they do not compare
character by character: a character diff can keep a character of one
highlight for its neighbour, or pull new text into a highlight. They
replace the changed region instead, widened so it never cuts through a
highlight. A highlight inside that region becomes your text; highlights
outside it keep their marks.

The update is built on a copy of the current note and delivered through
the code that applies incoming iCloud changes (`NotebookReplica.apply(_:)`),
moved into a shared method. That code already handles an open editor. A
note whose text has not downloaded yet is reported as pending, so the
caller keeps it and tries again. Catalog writes are batched, because each
one saves the whole catalog. Batches for one notebook run one at a time,
and the catalog write reads the notes' current names, folders and Trash
state, so a rename made while a batch runs is kept.

### Several devices

One device syncs at a time. A shared catalog entry names it; switching
writes that entry and nothing else, and only the person switches. Every
device reads the entry before each batch and stops if it is no longer the
syncing device. If two devices switch at once, Automerge picks the same
winner on every device.

This needs no lock, and the syncing device only keeps overlap rare. A
device that was offline can keep writing until it sees a switch, so the
rules below must hold however late changes arrive:

- **Both update the same block.** The note then holds two marked copies
  of it, and the map's block entry holds two values. Automerge shows the
  same winning value on every device, and the copy it names stays: text
  marked as that block with any other instance is deleted. A device that
  sees the winning value always keeps its copy, so at least one copy
  remains whatever subset each device saw. Typing that arrives late
  inside a removed copy still carries its mark. Readwise may not change
  that book again for a long time, so any device removes such copies when
  the change arrives through iCloud, not only during a Readwise sync; this
  only deletes integration text, and an error here never fails iCloud
  sync. The winner may hold an older Readwise version. The next update of
  that book sees a different hash and replaces it; if Readwise does not
  change the book again, the weekly full refresh does, because it compares
  each note block by block even when the book looks unchanged. Edits inside a
  removed copy stay in version history, as with any Readwise update.
- **Both import the same book.** Notes have ordinary random IDs, so this
  creates two notes and the book's catalog entry holds two values. The
  lower note ID wins and the entry records the other one as a duplicate.
  The duplicate stays where it is, for the person to delete; Note Actions
  marks it. Cleaning it up automatically could trash a note someone is
  editing on another device.
- **Both create the same category folder.** The lower folder ID wins for
  new notes. The other folder stays as it is.

Readwise sync only starts after the iCloud exchange that runs when the
app opens has finished, and never while iCloud sync is paused. A syncing
device whose template note is older than the version last used waits
until the newer version arrives.

### Where the state lives

New optional catalog keys, read the same way as the template and snippet
registers. Older versions skip keys they do not know.

- **`integration.<field>.<connection>`**, one entry per setting of a
  connection: the service, its state, the target folder and its name, a
  folder per category, the renderer version, the syncing device (a
  per-install ID and its type), the device that needs an update, the last
  sync time, and later the display settings and the template note with
  its last used version. Separate
  entries keep concurrent changes to different settings apart.
- **`integrationItem.<connection>.<hash of item key>`**, one per Readwise
  item:

  | Field | Used for |
  |---|---|
  | Note ID | Finding the note; "From Readwise" in Note Actions |
  | Hash of the last synced text | Skipping unchanged items unread |
  | Name and folder at that sync | Telling if you renamed or moved it |
  | State | Active, removed from Readwise, or deleted by you |
  | Duplicates | Losing notes for the same item, so none is lost |

  Keyed by the item, the entry outlives a deleted note, so a deletion
  stays a deletion on every device. Unknown fields are ignored, so a
  later version can add some.

- **iCloud Keychain:** the token.
- **This device only:** the "changed since" position for Readwise's
  export API, which only moves forward after the changes it covers are
  saved, the books to fetch again, and a fingerprint of what the notes
  were last rendered with.

A connection is created at setup with its own ID, and the token is stored
per connection. A notebook has one active connection per service.
Connecting a different Readwise account creates a new connection; notes
from the old one become ordinary notes. Notes are never matched across
connections. If two devices set up Readwise at the same time, both
connections are kept and Settings asks which one to keep, since they may
be different accounts. After a disconnect, a device that had not seen it
yet stops at its next check; notes it created meanwhile stay as ordinary
notes.

### Re-rendering

A template edit, the display settings, a newer renderer and Bring Back
Deleted Notes change notes whose Readwise data did not change. The
"changed since" position never returns those, so these run a full
refetch from Readwise. The syncing device keeps a fingerprint of the
renderer version, display settings, time zone and template it last
rendered with, and compares it before every sync, so a setting changed
on another device is noticed too. An interrupted full refetch starts
again at the next sync. Once a week the syncing device also refetches
every book, which repairs a highlight that an older device put back late
even when Readwise never changes that book again. A request to bring a
note back is saved before anything moves to Trash and kept until the
note exists again. The export API pages through all books, a few hundred
requests at most.

A full export leaves deleted books out, so every sync first asks for
books changed or deleted since the last one, also before a full refetch.

Readwise data that cannot be read is never applied, because a missing
highlight would look like a deleted one and take its block with it. A
book with a highlight that cannot be read waits and is fetched again
next time. A page with a book that cannot be read fails, and the
"changed since" position stays where it was.

### Readwise API

The export endpoint (`GET /api/v2/export/`) returns books with their
highlights. It takes `updatedAfter`, `includeDeleted` and `pageCursor`.
Books are identified by `user_book_id`, highlights by `id`, and each
highlight has a `readwise_url`. Requests send `Authorization: Token …`,
and `GET /api/v2/auth/` returns 204 for a valid token. The default rate
limit is 240 requests per minute; a 429 response carries `Retry-After`. A
revoked token stops Readwise sync and says so in Settings.

Setup saves the token before it creates the connection and removes it
again if that fails, so a Keychain error leaves nothing half set up. A
device that has the connection but no token, for example after the
Keychain lost it, shows a field to enter it again.

## Compatibility

Imported notes are ordinary notes. Older app versions sync, open, edit,
move, rename and trash them; they just never contact Readwise. Their edits
merge with later Readwise updates like any other edit, and a permanent
deletion on an older version counts as "deleted, don't import again".

The format gate does not change, there is no new kind of sync record, and
the CloudKit schema stays the same.

- **Marks** are part of the Automerge format. Every `Package.resolved` in
  the repository's history pins Automerge Swift 0.7.2 at one revision, so
  every build supports them. Older versions read only a note's plain
  text, and loading a note and Version History look only at the text.
  Their edits splice the same text object, so the marks stay.
- **Catalog keys** older versions do not know are skipped. Joining an
  offline notebook (`NotebookCatalog.forkJoiningOfflineNotebook`) and
  combining notebooks (`forkCombining`) copy only the keys they know, so
  the new keys must be added there. An older version that combines a
  notebook holding Readwise notes still drops them: those notes become
  ordinary notes, and the next sync imports the books again. That gives
  duplicates, not lost text.
- **No catalog copies.** Random IDs mean two devices never create the
  same catalog item, so the copies that versions before 0.32.0 mishandle
  never appear.

Between new versions, the shared settings record the renderer version. A
device running an older version than the one recorded pauses only
Readwise sync and asks for an update, so two versions never keep
replacing each other's blocks. iCloud sync and editing keep working.

## What the tests show

The marks were the risky part, so a spike pinned their behavior first.
`IntegrationMarksBehaviorTests` checks plain Automerge: typing inside a
block joins it and typing at its edges does not; copies stay apart only
with their own leading character; overlapping marks with one name show
one value; a character diff can pull new text into a mark; marks survive
saving and loading.

`NoteIntegrationTests` checks the update rules on notes, including two and
three devices with partial delivery, two devices cleaning up at once,
typing inside a copy while another device removes it, and a whole-text
replacement next to similar highlights. The multi-device cases repeat
with new random Automerge actors, because the outcome of a concurrent
insertion depends on their order.

`NotebookIntegrationUpdatesTests` checks the engine with replicas that
sync: folders and notes, renames and moves by the person and by the
service, an open note, deletion and Bring Back Deleted Notes, removed
items, a recreated folder, switching the syncing device, the version
check, a note whose text has not arrived, disconnecting, an overlap
during a switch, and combining notebooks.

### An older release

On 2026-11-14 the new NoteCore and the v0.31.0 release synced through the
[local sync service](local-sync-service.md). v0.31.0 is the oldest
release and predates the catalog copies fix in 0.32.0.

1. The new version connected Readwise and imported two books.
2. v0.31.0 received them, added a heading between two highlights, typed
   inside one highlight and added a line after another, renamed one note,
   moved the other into a new folder, and synced back.
3. The new version found every catalog entry and setting intact after
   v0.31.0's catalog writes, and the marks intact after its edits. The
   word typed inside a highlight had joined it, as designed. The next
   update replaced the two changed highlights, added a new one to the
   other book, and kept the heading and the extra line.
4. v0.31.0 received the updated notes.

This was a NoteCore test in each version's checkout, not the full app or
CloudKit.

### Size and speed

A local debug build imported 2,000 fictional books with 25 highlights
each, 50,000 highlights in all, in batches of 50. It took 106 seconds, at
2 to 3 seconds per batch, and the catalog grew to 317 KB. Adding new notes
to the catalog in one step per batch kept later batches from slowing
down; adding them one by one had grown to 12 seconds per batch. Changing
one highlight took under a second and grew that note's saved history by
about 260 bytes. A batch of 50 changed books, as after a template change,
took about 4 seconds. Release builds are faster; these numbers were not
measured on a device.

## Delivery

The spike ran on the branch first, without a pull request. Two stacked
pull requests follow, each opened only once it is ready to merge:

1. **Foundation**, with no visible change and no Readwise code. The
   engine (`NotebookIntegrationUpdates`) stays service-neutral, so JW
   Library or another integration can use it later. Commits, in order:
   1. This document.
   2. The marks behavior tests from the spike.
   3. Marked blocks with instance IDs, the block map, updates and
      duplicate removal in `NoteDocument`, and region replacement for
      whole-text saves in linked notes.
   4. The catalog entries, with joining and combining.
   5. The shared merge method in `NotebookReplica`.
   6. The engine: create, update, removed items, renames and moves,
      duplicate notes and folders, the syncing device, the version check
      and the last sync time.
2. **Readwise in Labs**, stacked on the first: the API client, the Jinja
   renderer with the built-in layout, Settings > Readwise and setup,
   scheduling, Note Actions, and custom templates, as separate commits.

The first PR holds the risk and gets a focused review. The second is
larger but mostly familiar work.

## Not in scope

- Writing changes back to Readwise.
- Reader's full document text.
- Background refresh while the app is closed. iOS decides when that runs,
  so it can come later.
- Custom filenames, for example `{{ author }} - {{ title }}`.

## Sources

- [Readwise export to Obsidian][readwise-obsidian]
- [Readwise's Obsidian plugin source][readwise-plugin]
- [Readwise API](https://readwise.io/api_deets)
- [Readwise Mirror](https://github.com/jsonMartin/readwise-mirror)
- [Obsidian block links](https://obsidian.md/help/links)
- [Obsidian 0.9.5 changelog][obsidian-changelog]

[readwise-obsidian]:
  https://docs.readwise.io/readwise/docs/exporting-highlights/obsidian
[readwise-plugin]: https://github.com/readwiseio/obsidian-readwise
[obsidian-changelog]:
  https://obsidian.md/changelog/2020-10-19-desktop-v0.9.5/
