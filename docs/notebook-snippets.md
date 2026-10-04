# Markdown snippets

Snippets insert reusable Markdown into an existing note. Their source is an
ordinary note; edit it in Files whenever you want to change the text. Snippet
registration is notebook metadata and follows the source's stable identity
through renames and moves. Templates and snippets are independent: a source
can be used for either or both.

## Register sources

In Files, open a note's context menu and choose **Use as Snippet**. Choose
**Use as Snippet Folder** on a folder to include its notes and all subfolders.
The same note appears once when sources overlap. Trashed or permanently deleted
notes and folders are excluded.

Choose **Stop Using as Snippet** or **Stop Using as Snippet Folder** to remove
that registration. This keeps the original notes. A note inside another
registered folder remains available through that folder; move it outside the
folder to stop including it.

## Find and edit sources

Open **Settings > Templates & Snippets** for an overview of registered folders
and all available snippets, including notes inside those folders. Each source
shows its notebook path. Templates keep their destination and filename options
in the same overview.

Open a snippet and choose **Edit Snippet** to edit its original Markdown note.
For a folder, **Show Folder in Files** reveals its contents. Type `{{` in a
snippet source for variable suggestions.

**Stop Using as Snippet** or **Stop Using as Snippet Folder** removes an
explicit registration and keeps the original notes. A source may remain
available through another registered folder or individual registration. For an
inherited snippet, the detail explains how to stop including it through its
folder.

## Insert into a note

Place the cursor in an existing note and tap **Insert Snippet** in the keyboard
formatting bar; swipe the bar if the button is offscreen. On Mac, open
**Formatting > Insert Snippet**. Select the source
by its filename, without the Markdown extension. Registered folders and their
subfolders appear as categories, including nested subfolders at any depth.
With one registered snippet folder, its name is omitted from the menu; notes
inside it and its subfolders appear directly. With multiple registered folders,
their names separate the sources. Individual sources outside registered folders
appear directly in the menu.

The current source body replaces the selected text, or inserts at the cursor
when nothing is selected. Whitespace and line breaks are preserved exactly;
no extra separators are added. One Undo removes the insertion. The inserted
text is independent of its source and can be edited normally.

If the note or selection changes while the source is loading, insertion stops
and asks you to choose the snippet again. Snippets are unavailable while using
History or when the note cannot be edited. For insertion inside an actively
edited rendered table cell, switch to Source mode first.

## Variables

When editing a snippet source, type `{{` to see variable suggestions, including
an example in your current regional format. Type a name to filter the choices;
tap a choice or use the arrow keys and Return to insert its literal token.
Escape or the close button dismisses the suggestions. This is available in
Source and Live Preview for registered notes and notes inside registered
snippet folders. Ordinary notes and template-only sources do not show these
suggestions.

The following exact tokens expand when inserting a snippet:

| Variable | Value |
| --- | --- |
| `{{date}}` | Date in your regional short format, including the year |
| `{{date:short}}` | Numeric day and month, regional order, without the year |
| `{{date:long}}` | Date in your regional long format |
| `{{date:iso}}` | Gregorian date, always `YYYY-MM-DD` |
| `{{time}}` | Local time in your preferred 12- or 24-hour format |
| `{{title}}` | Target note title without its Markdown extension |

For example, a source containing `## {{date}} - {{title}}` inserts a dated
heading using the note you are editing. Choose `{{date:iso}}` when a fixed,
sortable format is needed. The other date options use your regional calendar
and local time zone. Tokens expand throughout the body,
including code blocks. Unknown or incomplete tokens remain literal. A stray
opening `{{` does not stop a later valid token from expanding. Values
are expanded once; tokens within a substituted title are not expanded again.
The source itself stays unchanged.

Relative links are copied literally and resolve from the target note's
location. Linked notes and attachments are not copied.

## Verification boundaries

Core tests cover recursive discovery, stable identities, source text,
persistence, deletion, offline metadata merging, and variable expansion.
Native editor tests cover selection, Unicode, undo/redo, and stale insertion.
iPhone UI checks use the iCloud Dev build and fictional preview notebooks.
These layers do not establish physical-device or live CloudKit behavior.
