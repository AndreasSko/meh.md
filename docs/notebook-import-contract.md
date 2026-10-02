# Notebook file import

Import copies selected files or folders into the current notebook.
The source stays untouched. It is a one-time copy, not a watched folder or
external editing connection.

## Selection and review

Use Import Files from the notebook menu or Settings, then choose files or a
folder and the destination. A selected folder becomes a child of that
destination with the same name. Its nested folders, including empty folders,
stay nested. Individually selected files become direct children of the chosen
destination. Overlapping selections are read once.

Markdown-only selections follow the native picker directly into import.
Selections containing attachments show a confirmation with note, file, and
folder counts before adding anything to the notebook, including the current
requirement to update every device. Visible `.md` and `.markdown` files become
notes without regard to extension case. Other visible regular files become
attachments alongside notes in any folder. Hidden items, symbolic links,
packages, and nonregular files are skipped. Links are never followed into
another directory. Unreadable files, invalid notebook names, or invalid
UTF-8 Markdown fail preparation without creating a partial library.

Text is imported as UTF-8 without parsing or normalizing its Markdown.
Unicode, a UTF-8 byte-order mark, line endings, unsupported syntax, and
trailing newlines are retained. Existing item identities are never reused
based on a filename. Matching names remain separate using the notebook's
existing collision display rules.

Attachment bytes are copied and hashed while the selected source is available.
The file-provider read stays coordinated through the complete copy. The
notebook retains immutable contents under its attachment store by item UUID;
the catalog and import journal identify contents by SHA-256 digest and byte
count rather than embedding file bytes.
Each imported file has its own identity, even when its bytes match another.

Available filesystem creation and content-modification dates are captured
during preparation. Note dates remain in the staged job and Automerge note;
attachment dates are not currently catalog metadata. Missing note dates
remain unknown, including in older pending jobs. Import and resume do not
substitute the current time for the original note dates.

Content edits update the modification date. Rename, move, ordering, Trash,
and receiving synchronization leave it unchanged. Managed Markdown copies
receive known file dates where the destination filesystem supports them;
metadata is never inserted into Markdown bodies. Filesystem attributes remain
less portable than the authoritative dates stored in Automerge.

## Durability and retry

Preparation stores attachment bytes durably before showing the review.
Confirming import records a durable local job with stable identities, note
histories, and attachment descriptors. The version 2 job contains no
attachment bytes or source file URL; older Markdown-only version 1 jobs still
load. Note bodies are saved before their catalog references. All attachment
contents are verified before the complete tree becomes visible through one
catalog commit.

An interrupted job is offered for explicit resume when reopening the
notebook. Resume uses saved note histories and attachment bytes already in
the notebook store; it does not require source access. The job also retains
its chosen destination, so resuming does not ask for it again.
Once imported entries are visible, retry preserves subsequent edits, moves,
Trash state, and permanent deletion intent rather than resetting them.
A pending job prevents starting a second import until it has resumed or been
explicitly set aside. Set Aside keeps the raw job in an `import-recovery`
folder beside notebook storage, retaining note histories and attachment
descriptors. Already imported items stay in the catalog, and stored
attachment bytes remain available by UUID. Set Aside permits a fresh import
without deleting recovery data.
Reimporting the same source can create duplicates.
Choosing the same source again after completion intentionally makes a new
copy; it does not update or merge the earlier import.

Imported notes use ordinary notebook synchronization and structured Markdown
publication. Attachment contents transfer separately from catalog metadata.
Filesystem selection access ends after preparation; no source bookmark is
needed for resume. Canceling the review removes its prepared attachment
copies before a durable job exists.

## Verification

Record automated interruption, exact-byte, synchronization, and scale checks
alongside platform build and UI evidence in the milestone execution plan.
Physical device acceptance is separate from core fixture tests.
