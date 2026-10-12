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
            "Project update · Ready for review with the team."
        )
    }

    func testSeparatesHeadingsAndListItems() {
        let source = """
        # Recovery Sketch

        - Morning light over the ridge
        - Clear water below
        """

        XCTAssertEqual(
            NotebookRecentPreview.text(from: source),
            "Recovery Sketch · Morning light over the ridge · "
                + "Clear water below"
        )
    }

    func testEmptyBlocksDoNotDuplicateSeparators() {
        let source = """
        # Heading



        - First item



        - Second item
        """

        XCTAssertEqual(
            NotebookRecentPreview.text(from: source),
            "Heading · First item · Second item"
        )
    }

    func testKeepsInlineStylesAndSoftWrappedParagraphTogether() {
        let source = "A soft wrapped\n"
            + "paragraph with **bold** and _italic_ styling."

        XCTAssertEqual(
            NotebookRecentPreview.text(from: source),
            "A soft wrapped paragraph with bold and italic styling."
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
            "First · second it"
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
            "Example · # literal * punctuation · Documentation"
        )
    }
}
