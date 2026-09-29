# Managed Markdown copies

Status: one-way, read-only product-output policy active for the notebook.

## Activated notebook hierarchy

The activated app publishes active notes beneath
`Documents/Notebook Copies/Markdown`. Folder placement and derived display
names determine the hierarchy. A note name receives `.md` unless its catalog
name already has a Markdown suffix. Deterministic collision suffixes prevent
two catalog items from replacing one another. Trashed notes and folders are
omitted from this projection.

The `Notebook Copies` root is app-owned. A durable manifest beside `Markdown`
binds the directory to one notebook and tracks complete generations. The
publisher builds a replacement hierarchy first, then swaps it into place.
On restart it recovers an interrupted swap before publishing again. It fails
without replacing the current hierarchy if any active note snapshot is
missing or invalid. An unchanged refresh validates the managed paths and exact
file bytes, then leaves the existing hierarchy in place.

The publisher adopts only an empty root or one with its matching ownership
manifest. It does not delete or overwrite unrelated files. As with the first
copy writer, these files are product output: external edits are not imported
and can be replaced by the next complete publication.

## Earlier single-note copy

The milestone 1 `note.md` writer has been removed. Copies it created stay
where they are; the notebook neither maintains nor removes them. Its former
policy is in git history.
