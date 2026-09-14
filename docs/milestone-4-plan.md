# Milestone 4: Pleasant everyday writing

Updated: 2026-09-13

## Outcome and working method

Make daily writing and finding notes comfortable on Mac, iPhone, and iPad.
Start visual feedback on Mac, then verify the shared behavior on all devices.
Milestone 3 is merged. Work continues in one milestone thread, on a feature
branch in the existing checkout. Focused issues track deliverables and PRs.

Use Sol subagents with medium effort for bounded implementation and high
effort for difficult editor behavior or reviews. The coordinator integrates
and verifies their results. Quality takes priority over token savings.

## Privacy boundary

Personal notes and reference screenshots are private, local reference only.
Never include their content, paraphrases, names, file paths, infrastructure
details, or screenshots in commits, issues, PRs, logs, or public artifacts.
Subagents receive generic syntax requirements and entirely fictional samples.
Public fixtures are written from scratch in an unrelated subject area.

## Delivery order

1. **Markdown appearance:** establish a fictional reference fixture, improve
   typography, spacing, nested lists, wrapped-line alignment, quotes inside
   lists, highlights, strikethrough, links, and code presentation. Review the
   first Mac source-visible iteration before extending it.
2. **Automatic lists:** continue bullets and numbering on Enter, end an empty
   item, and indent/outdent selections predictably. Cover nested quotes and
   Unicode, and preserve native undo. Continue indentation, the existing
   bullet style, and quote markers; a second Enter on an empty continuation
   exits it. Tab moves the entire item, including an already-typed marker.
3. **Formatting commands:** bold, italic, headings, and links through native
   keyboard commands and a compact mobile toolbar. Selection and caret rules
   are shared, while platform controls remain native.
4. **Source and Live Preview:** prototype hiding/revealing heading, emphasis,
   and link markers around the selection. Verify cursor movement, selection,
   composition, copy/paste, undo, and remote updates before expanding support.
5. **Search:** offline title/content search, folder paths, match snippets,
   title-first ranking, navigation to matches, quick open, and in-note Find.
   Exclude Trash by default and reflect local and remote edits.
6. **Navigation comforts:** remember the current note and position, add a
   heading outline, focus mode, and pinned notes in small increments.

Clickable task checkboxes are a later follow-up. Rendered tables and images
remain outside this milestone. Source preservation applies to all syntax,
including unsupported constructs.

## Issue index

- [#26][issue-26]: Polish Markdown appearance and nested quotes.
- [#27][issue-27]: Continue and indent Markdown lists automatically.
- [#28][issue-28]: Add native Markdown formatting commands.
- [#29][issue-29]: Add Source and Live Preview editing modes.
- [#30][issue-30]: Find notes with offline search and quick open.
- [#31][issue-31]: Remember position and simplify note navigation.
- [#32][issue-32]: Support clickable Markdown task checkboxes.

The checkbox issue is a later follow-up, outside milestone four.

[issue-26]: https://github.com/AndreasSko/meh.md/issues/26
[issue-27]: https://github.com/AndreasSko/meh.md/issues/27
[issue-28]: https://github.com/AndreasSko/meh.md/issues/28
[issue-29]: https://github.com/AndreasSko/meh.md/issues/29
[issue-30]: https://github.com/AndreasSko/meh.md/issues/30
[issue-31]: https://github.com/AndreasSko/meh.md/issues/31
[issue-32]: https://github.com/AndreasSko/meh.md/issues/32

## Required quote behavior

Support ordinary blockquotes and quotes inside list items, including `* >`
after arbitrary list indentation. Include multiline quote text, nested lists,
tab and space indentation, inline emphasis/highlights, and editing back into
the surrounding list. Keep the literal source and whitespace unchanged.
This is an explicit feature requirement, not incidental color styling.

Quote backgrounds start at the quote marker, after list indentation, and
continue through spacing within the quoted section. A thin vertical accent
line marks the indented left edge of each quote panel. Fenced code uses a
continuous panel across the editor column. Strikethrough must be visibly
drawn, not merely recognized by the parser.

Adjacent quotes with different indentation form separate panels at their
own marker positions. Code panels have equal top and bottom padding.

## First visual checkpoint

Use `docs/fixtures/editor-showcase.md` as the entirely fictional reference.
Run `scripts/run_editor_preview.sh` to open the disposable Mac app. Use
`--build-only` to compile it without launching. Reset Sample restores the
fictional text; closing the app discards edits. Its appearance picker supports
light and dark checks; Narrow constrains the editor to a 440-point column.
The ellipsis button opens a temporary text-size slider. In the notebook,
Text Size in the note menu stores this preference on the current device.

The standalone editor preview uses the actual native editor without loading
the notebook, importing notes, publishing Markdown, or connecting to iCloud.

Run `scripts/run_editor_caret_check.sh` in a logged-in Mac session to verify
the actual native insertion indicator after five consecutive Returns at
17 and 22 points, in the middle and at the end of a note. This disposable
check uses fictional paragraphs and fails if the indicator is missing or
hidden. The headless SwiftPM host cannot provide that indicator, so its
matching XCTest explicitly skips; source/selection/viewport tests still run.

The first increment keeps syntax visible. Indentation guides, code-language
labels and token highlighting remain part of the appearance issue until
implemented and visually verified; the first pass must not claim them based
only on parser tests. A hidden-syntax editor is a separate checkpoint.

Acceptance:

- Text bytes, selection, and undo survive styling and appearance changes.
- Wrapped list/quote lines align with their content at narrow widths.
- Removing Markdown markers clears stale styles immediately.
- Escaped syntax and fenced/inline code do not acquire unrelated formatting.
- Light and dark appearance remain legible with native dynamic colors.
- Text-size changes preserve the source, selection, and undo history.
- Return keeps a visible caret and predictable scrolling on empty lines.
- Repeated Return checks inspect the native caret indicator's visibility,
  not just its calculated rectangle, in the middle and at the end of notes.
- Native editor tests pass, and Mac and iOS Simulator builds compile.
- Record actual Mac visual results separately from unperformed device checks.

## Deferred reliability work

Retain existing issues #20 (export/restore), #21 (replication profiling),
#22 (persisted sync pause), and #23 (broad fidelity fuzzing) in a later
reliability milestone. Keep #24 (automatic Mac receiving) visible as an open
device follow-up. Reproducible data-loss or blocking daily-use defects still
take precedence when encountered.

Use focused source-fidelity regressions with every editor change now; deferral
of the broad fuzzing project is not permission to weaken persistence or sync.
Reassess #4 against the existing syntax cache before duplicating that work.

## Progress

- The first source-visible visual iteration is ready for owner feedback.
  It includes 17-point Mac body text, paragraph spacing, quiet markers,
  highlights, visible strikethrough, alternating list/quote containers, and
  measured hanging indents for list, quote, and continuation paragraphs.
- Owner feedback added continuous, indented quote panels with an accent line,
  uniform fenced-code panels, and a device-local text-size control. Native
  attribute changes now touch only differing ranges; a deferred viewport
  repaint keeps Return caret geometry and existing syntax paint intact.
- The standalone Mac preview was inspected in light/dark appearance and a
  440-point column. This caught contrast and continuation-wrap problems that
  were corrected before the checkpoint. The preview never loaded a notebook.
- The feedback pass visually checked consecutive Return presses, 22-point
  text at a narrow width, and a new empty line inside a code block in dark
  appearance. The slider, size-step buttons, and default reset were checked.
- A subsequent caret report exposed a hidden native insertion indicator
  despite valid geometry. Refreshing AppKit's insertion-point lifecycle
  fixed it. The standalone regression fails without that hook and passes
  all 20 checks with it; five uninterrupted Returns were also checked in
  the preview. Deeper quote panels and symmetric code padding were refined.
- Sol implementation and independent review resolved delimiter-run,
  code-exclusion, alternating-container, and heading-prefix regressions.
- CodeRabbit feedback added per-editor syntax reuse across layout and drawing,
  and keeps text-size changes available after a failed save without replacing
  pending edits. Fenced-code parsing also reuses the document's line ranges.
- iPhone backgrounds now render with TextKit layout fragments instead of the
  whole text view's drawing surface. This keeps quote and code panels tied to
  their text during scrolling and keyboard resizing. The blue Done button
  was removed; starting a drag dismisses the keyboard, including short notes.
  The actual-app simulator regression verifies dismissal and resumed editing,
  and captures short quotes before and after reopening the keyboard. The
  inspected panels retain their height and position through that transition.
  Reproduce with `scripts/run_editor_quote_check.sh SIMULATOR_UDID STAGE`,
  where `STAGE` is `initial`, `scrolled`, or `resized`; inspect the screenshot
  for alignment. This installs only a separate fictional test app.
- Final local validation ran 344 Swift tests: 286 core, 53 native editor,
  and 5 app-model tests, with zero failures, plus 16 passing Python tests.
  One native-indicator XCTest explicitly skips in the headless host; the
  standalone actual-indicator check passes separately in the Mac session.
  Mac Local and generic iOS Simulator Local builds passed. No new physical
  iPhone/iPad or iCloud acceptance is claimed by these checks.
- No Live Preview, automatic-list, formatting-command, or search completion
  is claimed by this initial checkpoint.
- Next: owner feedback on the fictional Mac preview, then refine appearance
  and proceed to the remaining issues. Issue #26 remains open for guides,
  code-language presentation, and further visual acceptance.
