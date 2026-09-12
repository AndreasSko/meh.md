# Editor investigation

Updated: 2026-09-12

This records milestone 0 research and spike evidence. The resulting editor
architecture is accepted in
[ADR 001](decisions/001-native-text-editor.md).

## FSNotes revision and license

The investigation used the FSNotes `master` branch at commit
`4e44ff472b231c595d87199bcdba0e84e0be4d5d`, dated 2026-08-23. The upstream
repository is [glushchenko/fsnotes][fsnotes].

FSNotes is distributed under the MIT license. Copying its code or substantial
portions would require retaining its copyright and permission notice. The
current spike is an independent implementation and copies no FSNotes source,
so it introduces no FSNotes attribution requirement.

Relevant upstream paths inspected:

- `LICENSE`
- `FSNotes/EditorViewController.swift`
- `FSNotes/View/EditTextView.swift`
- `FSNotes/LayoutManager.swift`
- `FSNotes iOS/EditorViewController.swift`
- `FSNotes iOS/View/EditTextView.swift`
- `FSNotesCore/TextStorageProcessor.swift`
- `FSNotesCore/NotesTextProcessor.swift`
- `FSNotesCore/TextFormatter.swift`
- `FSNotesCore/CodeBlockDetector.swift`
- `FSNotesCore/Extensions/NSMutableAttributedString+.swift`
- `FSNotesCore/Business/Note.swift`
- `FSNotesCore/SwiftHighlighter/SwiftHighlighter.swift`

## How the FSNotes editor works

FSNotes has separate AppKit and UIKit editor controllers and custom text views.
The macOS controller is approximately 1,500 lines and its text view is
approximately 1,900 lines. The iOS controller is approximately 1,600 lines.
They mix editing with persistence, previews, attachments, preferences,
navigation, tags, and other application services.

An `NSTextStorageDelegate` drives styling. A full document is highlighted when
loaded; normal edits primarily reprocess the edited paragraph and repair
fenced-code ranges. `NotesTextProcessor` applies regular-expression-based font,
color, link, background, and paragraph attributes. A custom macOS layout
manager also draws code backgrounds and adjusts line heights.

With syntax hiding disabled, many ordinary Markdown markers remain visible.
However, task markers and image or file syntax can be converted into
`NSTextAttachment` characters while editing and reconstructed before saving.
That conflicts with meh.md's requirement that the editor always retain literal
Markdown characters.

FSNotes currently uses Swift Package Manager. Its packages include
`libcmark_gfm`, RNCryptor, ZipArchive, DropDown, SwipeCellKit,
TOCropViewController, and git/SSH-related libraries. The live inline styling
does not need `libcmark_gfm`; preview generation uses it. The syntax
highlighter is bundled source. None of these dependencies is needed by the
milestone 0 spike.

## Text-range risk

AppKit and UIKit text storage use UTF-16 offsets. FSNotes sometimes handles
that explicitly, but some editor and formatter paths construct `NSRange`
values using Swift `String.count`. Those measures differ for emoji and some
composed characters. Reusing the affected code would require a substantial
range audit.

The native spike therefore uses UTF-16 lengths and `NSRange(_:in:)` only at the
platform text boundary. This does not choose UTF-16 for file or document
storage: ordinary Markdown files can remain UTF-8. A later document core must
define one explicit conversion boundary between native text positions and
Automerge positions.

## Comparison

### Selective FSNotes reuse

Advantages:

- Mature behavior covers many Markdown forms and editing edge cases.
- Incremental paragraph highlighting is a useful performance reference.
- Native AppKit and UIKit text systems retain familiar selection and undo.

Disadvantages:

- The useful editor code spans several large, mutually dependent types.
- Some behavior deliberately replaces literal source with attachments.
- Range handling would need auditing before it was safe for Unicode text.
- The implementation brings far more application behavior than this spike
  needs.
- Copied code would require preservation of the MIT notice.

### Thin native wrapper

Advantages:

- It can guarantee that the backing `String` remains literal Markdown.
- It uses the existing native text systems without another dependency.
- Shared syntax detection can be kept separate from small platform adapters.
- UTF-16 handling and future position conversion can be explicit and tested.

Disadvantages and open risks:

- Input-method composition needs manual testing in both platform adapters.
- Selection and undo must be verified while attributes are reapplied.
- Layout-changing font attributes still require careful text-storage updates
  that do not enter the undo history.

## SwiftUI-only experiment

The macOS 27 and iOS 27 SDKs provide an attributed-string `TextEditor`, so an
all-SwiftUI implementation was built and tested. It kept the Markdown source
literal and rendered the expected styles on macOS.

Two approaches were exercised:

- Reapply derived attributes after observing a character change.
- Apply derived attributes inside a custom attributed-string binding setter.

Both approaches created an extra undo action before the user's text change was
undone. Temporarily disabling registration on SwiftUI's environment undo
manager did not change that result. SwiftUI also does not expose the editor's
marked-text state, so the spike could not coordinate styling with input-method
composition through supported APIs.

## Direction

Use FSNotes as a behavioral reference, not a source dependency. Continue the
fresh `NSTextView` and `UITextView` spike with shared syntax-range detection.
Keep Markdown markers visible, never insert attachments, and avoid changing
the source string while styling.

The current spike deliberately recognizes only headings, strong text,
emphasis, inline code, links, and list markers. This is enough to inspect the
approach; complete Markdown styling belongs to milestone 1.

Use SwiftUI around a thin native editable text surface, with TextKit 2 selected
explicitly on both platforms. Use rendering attributes for paint-only styles.
Use text-storage attributes, with undo registration suppressed, for font or
paragraph styles that affect layout. Shared syntax detection stays
platform-independent. This is recorded in
[ADR 001](decisions/001-native-text-editor.md).

TextKit 2 rendering attributes improve the bridge but do not replace it.
Applying a 40-point rendering font in a focused macOS probe left the line
fragment at its 14-point height. The milestone 0 heading style therefore stays
body-sized and bold. Larger headings are deferred until milestone 1, where
their layout, selection, undo, and composition behavior can be tested
together.

## Spike evidence

The spike uses a shared, dependency-free syntax detector plus thin AppKit and
UIKit adapters. Both explicitly use TextKit 2. Rendering attributes provide
colors and backgrounds without mutating the document; text-storage font
attributes are reapplied with undo registration disabled. Both adapters compare
and preserve their literal `String` value independently of styling.

Verified on 2026-09-12:

- A Debug macOS build completed successfully without code signing.
- A Debug generic iOS Simulator build completed successfully without code
  signing.
- The editor launched in an iPhone 17 simulator on iOS 27. The initial sample
  and its heading, strong, emphasis, code, link, and list styles were visible.
- The same sample and styles were visible in an 11-inch iPad Pro simulator on
  iPadOS 27.
- The owner exercised editing and undo on a physical iPhone.
- The shared syntax check passed for headings, emphasis, strong text, code,
  links, list markers, accents, emoji, and multiline source. Every detected
  range converted back to a valid Swift string range. It also verified that
  carets and selections are moved to valid composed-character boundaries for
  emoji and decomposed accents.
- In the macOS app, every Markdown marker remained visible while its span was
  styled.
- Replacing `naïve` with `über` retained the surrounding source and emoji.
  One native Undo restored `naïve` without a formatting-only undo step.
- A multiline paste containing `Eingefügt` and `🧑🏽‍💻` appeared
  verbatim. Native undo removed it, redo restored it, and a final undo restored
  the original sample.

Commands used:

```sh
xcodebuild -project meh.md.xcodeproj -scheme meh.md \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/meh-md-derived-mac \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project meh.md.xcodeproj -scheme meh.md \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/meh-md-derived-ios \
  CODE_SIGNING_ALLOWED=NO build

swiftc -module-cache-path /tmp/meh-md-swift-module-cache \
  meh.md/MarkdownSyntax.swift scripts/check_editor_syntax.swift \
  -o /tmp/meh-md-editor-syntax-check
/tmp/meh-md-editor-syntax-check
```

Not yet verified:

- marked-text behavior with an input method, which is intentionally not a
  milestone 0 requirement;
- selection behavior during externally supplied model changes;
- typing and undo on iPad;
- real-device iPad behavior;
- adaptive layouts beyond the basic iPad editor surface.

Long-document optimization is intentionally deferred. The current macOS spike
establishes the source, selection, and undo approach on a small representative
note; the platform checks listed above remain open.

[fsnotes]: https://github.com/glushchenko/fsnotes
