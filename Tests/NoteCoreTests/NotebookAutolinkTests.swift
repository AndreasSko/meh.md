import Foundation
import XCTest
@testable import NoteCore

final class NotebookAutolinkTests: XCTestCase {
    func testPlainAndAngleAddresses() {
        let text = "See https://example.com/a_(b), <https://x.org/?q=1> and www.apple.com.\n"
            + "Mail <me@example.com> or (http://example.com/path)."
        let links = NotebookLinkParser.parse(text)
        XCTAssertEqual(links.map(\.kind), [.url, .url, .url, .url, .url])
        XCTAssertEqual(links.map(\.destination), [
            "https://example.com/a_(b)", "https://x.org/?q=1", "www.apple.com",
            "me@example.com", "http://example.com/path",
        ])
        XCTAssertEqual((text as NSString).substring(with: links[1].range), "<https://x.org/?q=1>")
        XCTAssertEqual(links.map { NotebookLinkParser.url(of: $0)?.absoluteString }, [
            "https://example.com/a_(b)", "https://x.org/?q=1", "https://www.apple.com",
            "mailto:me@example.com", "http://example.com/path",
        ])
        let hashMail = NotebookLinkParser.parse("<me#tag@example.com>")[0]
        XCTAssertEqual(NotebookLinkParser.url(of: hashMail)?.absoluteString, "mailto:me%23tag@example.com")
        let nested = NotebookLinkParser.parse("https://a.com/x(y)))" + String(repeating: ")", count: 20_000))
        XCTAssertEqual(nested.map(\.destination), ["https://a.com/x(y)"])
    }

    func testAddressesInsideOtherSyntaxStayLiteral() {
        let text = "[label](https://example.com) [[https://wiki]] `https://code.example`\n"
            + "<!-- https://comment.example --> word.https://glued.example <not a link> https://"
        let links = NotebookLinkParser.parse(text)
        XCTAssertEqual(links.map(\.kind), [.markdown, .wiki])
        let adjacent = NotebookLinkParser.parse("(https://a.com)[[Note]] https://b.com[x](y.md)")
        XCTAssertEqual(adjacent.map(\.destination), ["https://a.com", "Note", "https://b.com", "y.md"])
    }

    func testAddressesOpenOutsideAndNeverResolveToNotes() {
        let note = NotebookLinkNote(id: UUID(), name: "www.example.com.md", path: "")
        let link = NotebookLinkParser.parse("www.example.com")[0]
        XCTAssertEqual(
            NotebookLinkResolver.resolve(link, sourceID: note.id, notes: [note]),
            .external(URL(string: "https://www.example.com")!)
        )
        let backlinks = NotebookLinkIndex(texts: [note.id: "https://example.com"], notes: [note])
        XCTAssertTrue(backlinks.backlinks(to: note.id).isEmpty)
    }
}
