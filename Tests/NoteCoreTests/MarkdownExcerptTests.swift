import Foundation
import XCTest

@testable import NoteCore

final class MarkdownExcerptTests: XCTestCase {
    private func plain(_ markdown: String) -> String {
        MarkdownExcerpt.plain(markdown).text
    }

    func testRemovesCommonMarkdown() {
        XCTAssertEqual(
            plain("## Project update\n\n**Ready** for _review_ with [the team](https://example.com)."),
            "Project update · Ready for review with the team."
        )
    }

    func testSkipsHeadingLinesOutsideCode() {
        let source = """
        # Weekly review
        ## Good
        - Lisbon is booked
          ### Meh
        ```
        # kept as code
        ```
        #hashtag stays
        """
        XCTAssertEqual(
            MarkdownExcerpt.plain(source, skippingHeadings: true).text,
            "Lisbon is booked · # kept as code · #hashtag stays"
        )
        XCTAssertEqual(
            MarkdownExcerpt.plain("    # indented code\nBody", skippingHeadings: true).text,
            "indented code · Body"
        )
        XCTAssertEqual(
            plain("# Weekly review\nBody"),
            "Weekly review · Body"
        )
        // A shorter or different fence inside a code block doesn't end it.
        XCTAssertEqual(
            MarkdownExcerpt.plain(
                "````\n```\n# kept as code\n~~~~\n````\nBody", skippingHeadings: true
            ).text,
            "``` · # kept as code · ~~~~ · Body"
        )
        // A fence with text after it doesn't end the code either.
        XCTAssertEqual(
            MarkdownExcerpt.plain(
                "```\n# kept\n``` swift\n```\nBody", skippingHeadings: true
            ).text,
            "# kept · ``` swift · Body"
        )
    }

    func testRemovesTasksWikiLinksAndHighlights() {
        XCTAssertEqual(
            plain("""
            Bring the [[Packing list]].
            - [x] Book flights
            - [ ] Reserve dinner in ==Bairro Alto==
            * [X] See [[Lisbon in May|Lisbon]]
            """),
            "Bring the Packing list. Book flights · Reserve dinner in Bairro Alto · See Lisbon"
        )
    }

    func testRemovesQuotesNumberedListsAndTables() {
        XCTAssertEqual(
            plain("""
            > Slow down. It's a ~~work~~ holiday.
            1. First
            2) Second
            | Day | What |
            | --- | :--- |
            | Thu | Tram 28 |
            """),
            "Slow down. It's a work holiday. First · Second · Day What · Thu Tram 28"
        )
    }

    func testKeepsLiteralPunctuation() {
        let source = "Use * as a wildcard, compare a_b, keep 2 ** 3, and 5 == 5."
        XCTAssertEqual(plain(source), source)
        XCTAssertEqual(plain("Keep this unmatched ** marker"), "Keep this unmatched ** marker")
        XCTAssertEqual(plain("#hashtag and [not a link]"), "#hashtag and [not a link]")
        XCTAssertEqual(plain("Ref [1] and [site](https://x.com)"), "Ref [1] and site")
    }

    func testCodeKeepsItsPunctuation() {
        XCTAssertEqual(
            plain("""
            ## Example

            ```
            # literal * punctuation ==
            ```

            Run `**not bold**` now.
            """),
            "Example · # literal * punctuation == · Run **not bold** now."
        )
    }

    func testCarriesRangeThroughDeletedSyntax() throws {
        let source = "- [ ] Reserve dinner in ==Bairro Alto==" as NSString
        let match = source.range(of: "Bairro")
        let result = MarkdownExcerpt.plain(source as String, keeping: match)
        let range = try XCTUnwrap(result.range)
        XCTAssertEqual((result.text as NSString).substring(with: range), "Bairro")
    }

    func testRangeAcrossSyntaxKeepsVisibleText() throws {
        let source = "a **bold** word" as NSString
        let match = source.range(of: "**bold**")
        let result = MarkdownExcerpt.plain(source as String, keeping: match)
        let range = try XCTUnwrap(result.range)
        XCTAssertEqual((result.text as NSString).substring(with: range), "bold")
    }

    func testRangeOnlyInsideSyntaxIsDropped() {
        let source = "==marked==" as NSString
        XCTAssertNil(MarkdownExcerpt.plain(source as String, keeping: NSRange(location: 0, length: 2)).range)
    }

    func testKeepsComposedCharacters() throws {
        let source = "**😀 Café** needle" as NSString
        let result = MarkdownExcerpt.plain(source as String, keeping: source.range(of: "needle"))
        XCTAssertEqual(result.text, "😀 Café needle")
        let range = try XCTUnwrap(result.range)
        XCTAssertEqual((result.text as NSString).substring(with: range), "needle")
    }

    func testSeparatesLinesUnlessASentenceEnded() throws {
        XCTAssertEqual(plain("Packing\nPassport\n\nDone.\nShoes"),
                       "Packing · Passport · Done. Shoes")
        let source = "- [ ] Tram\n- [ ] Ferry to Cacilhas" as NSString
        let result = MarkdownExcerpt.plain(source as String, keeping: source.range(of: "Ferry"))
        XCTAssertEqual(result.text, "Tram · Ferry to Cacilhas")
        let range = try XCTUnwrap(result.range)
        XCTAssertEqual((result.text as NSString).substring(with: range), "Ferry")
    }

    func testKeepsALiteralMiddleDotInTheMatch() throws {
        let source = "**a·b**" as NSString
        for needle in ["·b", "·"] {
            let result = MarkdownExcerpt.plain(source as String, keeping: source.range(of: needle))
            let range = try XCTUnwrap(result.range)
            XCTAssertEqual((result.text as NSString).substring(with: range), needle)
        }
    }
}
