# Note templates

Use an ordinary note as a starting point for new notes. Template registration
and defaults are notebook metadata; the source Markdown remains unchanged.
New notes receive the current text, a new identity, and fresh history.
Later edits to either note do not change the other.

## Register and manage templates

In Files, open a note's context menu and choose **Use as Template**. The same
action is available in Note Actions and the Recents context menu.
Choose **Use as Template Folder** for a folder to include all active notes in
that folder and its subfolders. A note appears once even when it belongs to
multiple registered sources. Trashed sources and notes are unavailable.

Open **Settings > Templates** to see registered sources and the combined list
of available templates. Edit a source note with **Edit Template**. Removing a
registration keeps the original note or folder. A note supplied by a template
folder remains available until it leaves that folder or the folder is no
longer registered.

## Create a note

Hold the **+** button and choose **New from Template**, or use that action in
Browser Actions. Selecting a template immediately creates and opens the note
using its saved filename and destination defaults. Change those defaults in
**Settings > Templates**; rename or move the new note afterward if needed.
An ordinary tap on **+** still creates a blank note. On iPhone and iPad, the
app icon's long-press menu also offers **New from Template**, which opens the
picker.

## Defaults and inheritance

Each note and registered folder can define a destination and filename pattern.
An inherited setting comes from the nearest registered ancestor folder with
an explicit value, then from the usual new-note behavior. Note overrides take
precedence over folder defaults. Destination and filename inherit separately.
The usual destination is the folder configured under **Settings > New Notes**;
the usual filename is the current date with a collision suffix when needed.

The template's source folder does not determine where its copies are stored.
Configured destinations and sources follow their stable identities through
renames and moves. If a configured destination is unavailable, creation reports
the problem in the picker. Update the template destination in Settings before
trying again.

Filename patterns support literal text and these variables:

| Variable | Value |
| --- | --- |
| `{{date}}` | Local calendar date, `YYYY-MM-DD` |
| `{{time}}` | Local time, `HH-mm` |
| `{{template}}` | Source note name without its Markdown extension |

For example, `{{date}} - {{template}}` suggests `2026-10-02 - Meeting.md` for
a template named `Meeting.md`. Settings shows a preview and rejects unsupported
variables or invalid filenames. Existing names receive a numbered suffix;
creating from a template never replaces an existing note.

## Variables in the body

The note body supports the same variables as snippets, such as `{{date}}`,
`{{date:iso}}`, `{{time}}`, and `{{title}}`. See
[snippet variables](notebook-snippets.md#variables) for the full list. They
expand once, when the new note is created; the template keeps its tokens.
`{{title}}` is the new note's title, after any numbered suffix. The body and
the filename use the same moment in time.

Body and filename variables are separate lists. In the body, `{{date}}` uses
your regional short format; in a filename it is always `YYYY-MM-DD`.
`{{template}}` works only in filenames and stays literal in the body. Type
`{{` while editing a template source to see the body variables.

Variables expand anywhere in the body, including frontmatter and links.
Everything else is copied literally. Relative links are therefore
interpreted from the new note's location; a different destination may
change their meaning. Templates do not copy linked
notes or attachment files.

## Verification boundaries

Core checks cover discovery, inheritance, persistence, copying, body
variables, and concurrent catalog updates. UI checks use the iCloud Dev
build with an isolated preview notebook and fictional data. Those checks do
not establish physical-device or live CloudKit behavior; report those layers
separately when validating a PR.
