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

## Insert into a note

Place the cursor in an existing note and tap **Insert Snippet** in the keyboard
formatting bar; swipe the bar if the button is offscreen. On Mac, open
**Formatting > Insert Snippet**. Select the source
by its filename, without the Markdown extension. Registered folders and their
subfolders appear as categories, including nested subfolders at any depth.
Individual sources outside registered folders appear directly in the menu.

The current source body replaces the selected text, or inserts at the cursor
when nothing is selected. Whitespace and line breaks are preserved exactly;
no extra separators are added. One Undo removes the insertion. The inserted
text is independent of its source and can be edited normally.

If the note or selection changes while the source is loading, insertion stops
and asks you to choose the snippet again. Snippets are unavailable while using
History or when the note cannot be edited. For insertion inside an actively
edited rendered table cell, switch to Source mode first.

## Variables

The following exact tokens expand when inserting a snippet:

| Variable | Value |
| --- | --- |
| `{{date}}` | Local calendar date, `YYYY-MM-DD` |
| `{{time}}` | Local time, `HH:mm` |
| `{{title}}` | Target note title without its Markdown extension |

For example, a source containing `## {{date}} - {{title}}` inserts a dated
heading using the note you are editing. Tokens expand throughout the body,
including code blocks. Unknown or incomplete tokens remain literal. Values
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
