# Wave 2: organize the notebook

Issues #44 and #42 follow merged Wave 1 PRs #47 and #48. Work starts from
`0c188e1` in an isolated worktree. The saved checkout is left untouched.

## Accepted behavior

- Sort is a one-time action that saves a folder's order. It can be repeated
  whenever needed; subsequent dragging changes the saved manual order.
- New and moved-in items append. Existing notes keep their identities.
- Automerge merges individual ordering changes. Different-item reorders can
  combine; competing changes to one item have a deterministic winner. A
  reorder in an old folder cannot override a concurrent move elsewhere.
- Imported creation and content-modification dates are retained when present.
  Unknown legacy or missing dates remain unknown. New notes use creation time.
- Content edits update modification dates. Renaming, moving, sorting, Trash,
  and receiving synchronization do not count as content edits.
- Dates live in Automerge and are applied to managed Markdown file attributes
  where supported. Markdown bodies contain only the user's original source.
- Recents and browser selection remain device-local. Browser operations must
  preserve pending text, the editor session, and text undo.

Name sorting offers both directions. Date sorting offers newest and oldest
first, places unknown dates last, and groups folders first by name. Manual
ordering can interleave folders and notes. Ordering in Trash is read-only.

## Pull request sequence

1. Add backward-compatible order/date metadata, import journal evolution, and
   managed file dates. Verify convergence, old data, exact bytes, and retry.
2. Add sibling-scoped drag ordering and repeatable folder/root sort actions.
   Keep moving into folders distinct from ordering their siblings.
3. Add scene-local multiselection, atomic batch move/Trash, compensating
   browser undo, and swipe to Trash. Selecting an ancestor and descendant
   operates on the ancestor once and preserves its subtree.

Each PR receives local checks and coordinator review before requesting
CodeRabbit. Descendants remain unreviewed until their parent is stable. Avoid
pushes during review and verify the actual commit coverage before closeout.
These PRs are prepared for review, without automatic merging.

## Validation

Baseline `swift test --disable-sandbox` passed on current main. Wave 2 checks
will cover legacy documents and pending imports, concurrent reorder/move,
atomic batch failure, source bytes, content dates, managed attributes, local
Recents, editor undo, and Mac/iOS builds and interaction.

Physical-device evidence is separate from simulator and deterministic replica
tests. Appearance/checklists, search/navigation, and multiple windows remain
outside this wave.

### Metadata checkpoint, 2026-09-14

The integrated workspace passed the repository's loopback validation: 442
Swift tests (one platform-only skip) and 16 Python tests. A subsequent focused
test verified invalid import dates leave no journal, body, or catalog change.
Coverage includes three-replica delivery permutations, 2,000 insertions into
one order gap, legacy data, source-free import resume, and stable publication.
Mac and iOS Simulator builds passed with the dependent ordering UI present.
Coordinator and independent cross-review found and resolved legacy ordering
initialization and timestamp precision issues before this checkpoint.
