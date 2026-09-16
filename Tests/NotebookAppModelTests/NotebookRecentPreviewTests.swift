import XCTest
@testable import NotebookAppModel

final class NotebookRecentPreviewTests: XCTestCase {
    func testRemovesMarkdownPresentationFromPreview() {
        let source = """
        ## Project update

        **Ready** for _review_ with [the team](https://example.com).
        """

        XCTAssertEqual(
            NotebookRecentPreview.text(from: source),
            "Project update Ready for review with the team."
        )
    }

    func testPreservesMeaningfulLiteralPunctuation() {
        let source = "Use * as a wildcard, compare a_b, and keep 2 ** 3."

        XCTAssertEqual(
            NotebookRecentPreview.text(from: source),
            source
        )
    }

    func testProducesOneLineAndHonorsCharacterLimit() {
        XCTAssertEqual(
            NotebookRecentPreview.text(
                from: "First\n\n- second item\n- third item",
                characterLimit: 17
            ),
            "First second item"
        )
    }

    func testMalformedMarkdownFallsBackWithoutDeletingCharacters() {
        let source = "Keep this unmatched ** marker"

        XCTAssertEqual(
            NotebookRecentPreview.text(from: source),
            source
        )
    }

    func testFencedCodeKeepsMarkdownPunctuationLiteral() {
        let source = """
        ## Example

        ```
        # literal * punctuation
        ```

        [Documentation](https://example.com)
        """

        XCTAssertEqual(
            NotebookRecentPreview.text(from: source),
            "Example # literal * punctuation Documentation"
        )
    }
}
