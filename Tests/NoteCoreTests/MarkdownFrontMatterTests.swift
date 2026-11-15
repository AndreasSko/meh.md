import Foundation
import XCTest
@testable import NoteCore

final class MarkdownFrontMatterTests: XCTestCase {
    private func parse(_ text: String) -> (MarkdownFrontMatter?, NSString) {
        let source = text as NSString
        return (MarkdownFrontMatter.parse(source), source)
    }

    func testReadsKeysValuesAndLists() throws {
        let text = """
        ---
        author: Mira Holt
        url: "https://example.com/garden"
        tags: [habit, "two words"]
        ---
        Body
        """
        let (parsed, source) = parse(text)
        let frontMatter = try XCTUnwrap(parsed)
        XCTAssert(source.substring(with: frontMatter.range).hasSuffix("---\n"))
        XCTAssertEqual(frontMatter.properties.map(\.label), ["Author", "URL", "Tags"])

        let author = frontMatter.properties[0]
        XCTAssertEqual(source.substring(with: author.keyRange), "author: ")
        XCTAssertEqual(author.value.map(source.substring(with:)), "Mira Holt")

        let url = frontMatter.properties[1]
        XCTAssertEqual(url.value.map(source.substring(with:)), "https://example.com/garden")
        XCTAssertEqual(url.syntax.map(source.substring(with:)), ["\"", "\""])

        let tags = frontMatter.properties[2]
        XCTAssertNil(tags.value)
        XCTAssertEqual(tags.items.map(source.substring(with:)), ["habit", "two words"])
        XCTAssertEqual(tags.separators.map(source.substring(with:)), [", "])
        XCTAssertEqual(Set(tags.syntax.map(source.substring(with:))), ["[", "]", "\""])
    }

    func testReadsABlockListBelowAKey() throws {
        let text = "---\ntags:\n  - habit\n  - garden\nstatus: draft\n---\n"
        let (parsed, source) = parse(text)
        let frontMatter = try XCTUnwrap(parsed)
        let tags = frontMatter.properties[0]
        XCTAssertEqual(source.substring(with: tags.keyRange), "tags:")
        XCTAssertEqual(tags.items.map(source.substring(with:)), ["habit", "garden"])
        XCTAssertEqual(tags.syntax.map(source.substring(with:)), ["  - ", "  - "])
        XCTAssertEqual(tags.itemLines.map(source.substring(with:)), ["  - habit", "  - garden"])
        XCTAssertEqual(source.substring(with: tags.lines), "tags:\n  - habit\n  - garden")
        XCTAssertEqual(frontMatter.properties[1].label, "Status")
    }

    func testLeavesYAMLItCannotShowAsRowsAlone() {
        for text in [
            "---\nauthor:\n  name: Mira\n---\n",
            "---\nsummary: |\n  Two\n  lines\n---\n",
            "---\n# comment\nauthor: Mira\n---\n",
            "---\nauthor: Mira # comment\n---\n",
            "---\nauthor: Mira\n\nstatus: draft\n---\n",
            "---\ntags: [a, [b]]\n---\n",
            "---\nmap: {a: 1}\n---\n",
            "---\nauthor: Mira\n",
            "Body\n---\nauthor: Mira\n---\n",
            "---\njust text\n---\n",
            "---\npeople:\n  - name: Mira\n---\n",
            "---\npeople: [name: Mira]\n---\n",
            "---\nnested:\n  - - a\n---\n",
            "---\nnote: a: b\n---\n",
            "---\nkind: !tag value\n---\n",
        ] {
            XCTAssertNil(MarkdownFrontMatter.parse(text as NSString), text)
        }
    }

    func testReadsEmptyFrontMatterAndEmptyValues() throws {
        let (empty, _) = parse("---\n---\nBody")
        XCTAssert(try XCTUnwrap(empty).properties.isEmpty)
        let (parsed, source) = parse("---\ntags: []\nstatus:\n---")
        let frontMatter = try XCTUnwrap(parsed)
        XCTAssert(frontMatter.properties[0].items.isEmpty)
        XCTAssertEqual(source.substring(with: frontMatter.properties[1].keyRange), "status:")
        XCTAssertEqual(NSMaxRange(frontMatter.range), source.length)
    }

    func testQuotedValuesWithEscapesKeepTheirQuotes() throws {
        let text = "---\nauthor: 'O''Brien'\ntitle: \"Say \\\"hi\\\"\"\nplain: 'Mira'\n---\n"
        let (parsed, source) = parse(text)
        let frontMatter = try XCTUnwrap(parsed)
        XCTAssertEqual(frontMatter.properties[0].value.map(source.substring(with:)), "'O''Brien'")
        XCTAssertEqual(frontMatter.properties[0].syntax, [])
        XCTAssertEqual(frontMatter.properties[1].value.map(source.substring(with:)), "\"Say \\\"hi\\\"\"")
        XCTAssertEqual(frontMatter.properties[2].value.map(source.substring(with:)), "Mira")
    }
}
