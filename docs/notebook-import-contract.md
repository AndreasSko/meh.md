# Markdown library import

Import copies selected Markdown files or folders into the current notebook.
The source stays untouched. It is a one-time copy, not a watched folder or
external editing connection.

## Selection and review

Use Import Markdown in the notebook toolbar, then choose files or a folder.
A selected folder becomes a top-level folder with the same name. Its nested
folders, including empty folders, stay nested. Individually selected files
become top-level notes. Overlapping selections are read once.

The review shows note/folder counts and skipped paths before adding anything
to the notebook. Visible `.md` and `.markdown` files are accepted without
regard to extension case. Hidden items, symbolic links, packages, and other
file types are skipped. Links are never followed into another directory.
Unreadable Markdown, invalid notebook names, or invalid UTF-8 fail preparation
with an error instead of creating a partial library.

Text is imported as UTF-8 without parsing or normalizing its Markdown.
Unicode, a UTF-8 byte-order mark, line endings, unsupported syntax, and
trailing
newlines are retained. Existing note/folder identities are never reused based
on a filename. Matching names remain separate using the notebook's existing
collision display rules.

## Durability and retry

Confirming import first records a durable local job with stable identities
and note histories. Note bodies are saved before their catalog references.
The complete folder tree becomes visible through one catalog commit.

An interrupted job is offered for explicit resume when reopening the
notebook. Resume uses the staged copy and does not require source access.
Once imported entries are visible, retry preserves subsequent edits, moves,
Trash state, and permanent deletion intent rather than resetting them.
A pending job prevents starting a second import until it has resumed or been
explicitly set aside. Set Aside keeps the raw job in an `import-recovery`
folder beside notebook storage, retaining staged bodies and any already
imported notes. It permits a fresh import without deleting recovery data.
Reimporting the same source can create duplicates.
Choosing the same source again after completion intentionally makes a new
copy; it does not update or merge the earlier import.

Imported notes use ordinary notebook synchronization and structured Markdown
publication. Filesystem selection access ends after preparation; no source
bookmark is needed for resume.

## Verification

Record automated interruption, exact-byte, synchronization, and scale checks
alongside platform build and UI evidence in the milestone execution plan.
Physical device acceptance is separate from core fixture tests.
