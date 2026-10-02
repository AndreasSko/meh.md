# Connected notes

Connect notes with Wikilinks or Markdown links, follow those links, return to
the previous reading position, and find notes that link to the current note.
The feature uses literal Markdown and adds no permanent sidebar or graph.

## Try it locally

Use the `meh.md iCloud Dev` scheme on macOS or an iPhone/iPad simulator.
Import the `Connected Notes` folder under `docs/fixtures/connected-notes` as a
folder, rather than importing each file separately. Open `Welcome` and follow
the links to `Project` and `Meeting`.

On Mac, click a rendered link in Live Preview to open it. In the active
paragraph or Source mode, ordinary clicks edit the literal text; Command-click
follows the link. Shift-click retains native text selection.
Clickable links use the native pointing-hand cursor. Following a link resolves
from catalog paths and reads only the destination note, without scanning the
notebook's other note bodies.
On touch devices, tap a rendered link with the keyboard dismissed; while
editing, use the contextual `Open Linked Note` action. Link destinations open
without keyboard focus.
On iPad, a compatible mouse or trackpad highlights the visible label of a
clickable link. Editing and Source mode retain the native text pointer.

Obsidian also opens links with an ordinary click, but its Command-click opens a
new tab. The app has no note tabs; Command-click remains an explicit way to
follow a link in the same window. See [Obsidian link controls][obsidian-tabs].

[obsidian-tabs]: https://obsidian.md/help/tabs

On compact iPhone and iPad layouts, following a link adds a native navigation
step. The standard Back button and edge swipe return to the preceding note,
then to Files after reaching the start of the journey. There is no separate
pair of navigation arrows. Mac and wide iPad show a Back button only while a
link journey has an earlier visit. Mac also offers Go Forward in Note Actions
with Command-]; Command-[ goes Back. Opening a note directly through Files,
Recents, Search, or New Note starts a fresh journey.
Each visit stores its own reading position; history belongs to the window.
On compact layouts, the positioned transition preview remains visible until
the live editor has restored its reading anchor, preventing a flash at the top.
A retained preview applies its captured position during its first native
layout, so it is ready when a link transition exposes the preceding visit.
Following links and navigating history expands the destination's folders and
reveals its row in Files, without switching away from the editor. On Mac the
native row selection tracks the destination unless a batch selection is active.

`Note Actions > Linked from…` shows incoming links grouped by source note.
Tap an excerpt to open its actual occurrence. Unavailable note bodies are
reported rather than counted as empty notes.

Type `[[` for title/path/alias suggestions, then `#` for headings. Arrow keys,
Return, and Escape work with a hardware keyboard. All four arrows move through
suggestions and keep the selected result visible without moving the caret.
Modified arrows retain native text selection. Selecting a suggestion
inserts a Wikilink. The existing Insert Link command opens a note/URL picker
and inserts a relative Markdown link. Both insertions use native editor Undo.
Title/path suggestions are available from the catalog immediately; aliases,
headings, and backlinks appear as note bodies finish loading.
Opening a missing note offers explicit creation; destination folders must
already exist. An ambiguous filename opens a chooser with folder paths.

For isolated automated UI checks, Debug iCloud Dev also accepts
`MEH_NOTEBOOK_PREVIEW=1` with a unique alphanumeric/hyphen/underscore
`MEH_NOTEBOOK_PREVIEW_RUN` value. This stores a separate local fixture notebook
and bypasses CloudKit. Normal iCloud Dev launches keep their usual cloud mode.

## Implementation

- `NotebookLinkParser` interprets explicit Wikilinks and inline Markdown links,
  labels, path destinations, headings, and existing block identifiers. UTF-16
  ranges are shared by presentation, activation, indexing, and export. Code,
  comments, and frontmatter are excluded. Incomplete Markdown links remain
  styled during typing, but are excluded from semantic resolution.
- `NotebookLinkResolver` combines source location with catalog paths and
  stable note IDs. It reports resolved, ambiguous, missing, external, and
  unsupported destinations. Unknown attachment types and embeds cannot create
  a Markdown note accidentally. Backlink indexing and export reuse normalized
  path/suffix lookups rather than scanning all notes for every occurrence.
  Wikilinks resolve colon-containing note names before considering supported
  external URLs; explicit Markdown URLs retain their external meaning.
- `NotebookLinkIndex` derives incoming links from locally readable text.
  `NotebookLinkState` caches an on-demand corpus against search revisions and
  computes backlinks, headings, and aliases away from the main actor. Catalog
  descriptors include unavailable bodies, so pending downloads still resolve
  as existing notes. Reading unopened bodies creates no editor session.
- Imported folder roots carry synchronized `importRootID` metadata. Root
  identity survives wrapper renames; local moves update descendant scopes.
  Separately imported folders do not silently share bare Wikilink names.
  Standalone file imports use the ordinary notebook scope.
- Rename, move, batch move, and browser Undo preserve literal note text.
  Former paths and import scopes are recorded against stable note identities
  in the same durable catalog write as the structural change. The shared
  resolver uses those synchronized locations for old and offline links.
- Export translates resolved relationships into the exported hierarchy while
  preserving labels, fragments, and valid destinations. Exporting one imported
  root produces a standalone vault; combined exports handle scoped duplicate
  names and filename collisions. Automatic backups keep exact source text.

## Reliability decisions

A two-replica test of automatic destination replacement reproduced corrupted
links after concurrent offline renames: each device independently inserted its
new destination into the same Markdown range. A retry journal cannot prevent
that concurrent text merge. Structural operations therefore preserve Markdown
and commit stable-identity location history atomically with the catalog.

This handles interruption without partially updating other documents. Notes
whose bodies have not downloaded can still resolve their former destinations.
Concurrent changes to note prose are preserved. Import/export round-trip tests
verify portable files with current destinations rather than requiring another
app to understand meh.md's catalog metadata.

If current and historical paths could mean different notes, show the existing
chooser. This includes reusing a renamed note's former path and moving a source
between folders or imported roots with different same-name destinations.
Literal Markdown has no creation-time identity, so a new link to a reused path
may also require choosing. Ambiguous links remain unchanged during export.

## Remaining boundaries

This feature does not provide complete Obsidian vault compatibility. The
following capabilities and evidence remain separate:

- Imported roots from earlier app versions have no origin metadata. Reimport
  the fixture folder to establish its scope; no heuristic migration is
  attempted.
- The index reads the corpus on demand rather than maintaining an incremental
  persistent index. A synthetic 2,000-note/20,000-link index took about 0.73
  seconds locally; cold body reads still need large-notebook measurement.
  Rename/move records catalog descriptors without reading every note body.
- Reference-style Markdown links, asset import, embeds, Canvas, unlinked
  mentions, graph views, and block-authoring tools are outside this feature.
  Unsupported syntax remains literal text. Alias parsing covers ordinary
  frontmatter scalar/flow/block lists, not arbitrary YAML.
- Duplicate names trigger a chooser instead of reproducing undocumented
  Obsidian tie-breaking. No live Obsidian comparison has been performed.
- Suggestions use one temporary glass surface with full-width choices and
  native-sized touch targets. They remain below the editor on all platforms;
  caret-adjacent Mac placement is separate polish.
- App-managed Markdown copies retain literal source text, including old paths.
  Use Export for portable links after renames and moves. Automatic backups also
  retain literal text by design.
- Tests exchange records between local replicas. They do not establish live
  cross-device CloudKit timing or physical-device interaction behavior.

## Validation

Core tests cover parsing exclusions and escaping, Unicode, mixed destinations,
ambiguous names, scoped imports, headings/blocks, aliases, backlink grouping,
unavailable bodies, atomic rename/move/Undo, interrupted writes, concurrent
offline renames, old-path links, source edits, and export/import round trips.
Native editor tests cover insertion snapshot guards, literal source/Undo, live
preview spans, and incremental syntax behavior. App model tests cover visit
history and completion detection.

`NotebookLinksUITests` uses an isolated fictional notebook to exercise passive
link following, native Back/swipe, target-scoped backlinks, occurrence
navigation, `[[` completion, and a fresh Back route after inline rename.
Build and runtime results are recorded in PR #173. Simulator results do
not establish physical-device or live CloudKit behavior.

Automated PR execution of these UI checks, a runnable iOS native editor test
host, and frame analysis for brief transition flicker are tracked in
[issue #183](https://github.com/AndreasSko/meh.md/issues/183).
