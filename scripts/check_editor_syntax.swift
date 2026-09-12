import Foundation

@main
enum EditorSyntaxChecks {
    static func main() {
        let source = """
        # Café 👋🏽

        Keep **literal Markdown** and _naïve text_.
        Use `let greeting = \"Hej\"` and [a link](https://example.com).

        - First line
        - Second line
        """
        let original = source
        let spans = MarkdownSyntax.spans(in: source)

        require(source == original, "syntax detection changed its input")
        require(!spans.isEmpty, "no syntax spans were detected")
        require(spans.contains { $0.role == .heading(level: 1) }, "no heading")
        require(spans.contains { $0.role == .strong }, "no strong text")
        require(spans.contains { $0.role == .emphasis }, "no emphasis")
        require(spans.contains { $0.role == .code }, "no inline code")
        require(spans.contains { $0.role == .link }, "no link")
        require(
            spans.filter { $0.role == .listMarker }.count == 2,
            "list markers were not detected"
        )

        for span in spans {
            require(
                Range(span.range, in: source) != nil,
                "a syntax span split a Unicode character"
            )
        }

        let multilinePaste = """
        first line
        zweite Zeile mit Umlauten: äöü
        emoji line: 🧑🏽‍💻
        """
        let combined = source + "\n" + multilinePaste
        _ = MarkdownSyntax.spans(in: combined)
        require(
            combined.hasSuffix(multilinePaste),
            "multiline source was not preserved"
        )

        let emojiText = "A👋🏽B"
        let emojiRange = (emojiText as NSString)
            .range(of: "👋🏽")
        let emojiCaret = emojiText.clampedSelection(
            NSRange(location: emojiRange.location + 1, length: 0)
        )
        require(
            emojiCaret == NSRange(location: emojiRange.location, length: 0),
            "emoji caret was not moved to a composed-character boundary"
        )

        let accentText = "Cafe\u{301}"
        let accentRange = (accentText as NSString)
            .rangeOfComposedCharacterSequence(at: 3)
        let accentSelection = accentText.clampedSelection(
            NSRange(location: 4, length: 1)
        )
        require(
            accentSelection == accentRange,
            "accent selection was not expanded to a character boundary"
        )

        require(
            "short".clampedSelection(NSRange(location: 99, length: 0))
                == NSRange(location: 5, length: 0),
            "selection beyond new text was not clamped to its end"
        )

        let nestedHeading = "# _Bold italic_"
        require(
            fontTraits(in: nestedHeading, at: "Bold") == [.bold, .italic],
            "nested heading emphasis did not compose font traits"
        )

        let nestedCode = "**`bold code`**"
        require(
            fontTraits(in: nestedCode, at: "bold code")
                == [.bold, .monospaced],
            "strong code did not compose font traits"
        )

        let literalCode = "`**not bold**`"
        require(
            fontTraits(in: literalCode, at: "not bold") == [.monospaced],
            "Markdown-like text inside code received semantic styling"
        )

        print("Editor syntax checks passed")
    }

    private static func fontTraits(
        in source: String,
        at substring: String
    ) -> MarkdownFontTraits? {
        let location = (source as NSString).range(of: substring).location
        return MarkdownSyntax.fontRuns(in: source).first { run in
            NSLocationInRange(location, run.range)
        }?.traits
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fputs("Editor syntax check failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
