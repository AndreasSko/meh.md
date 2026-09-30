import Foundation
import XCTest
@testable import NoteCore

final class NotebookLinksTests: XCTestCase {
    func testWikiRangesLabelsAndUnicodeAreUTF16() {
        let text = "🙂 [[Projects/Überblick#Next steps|the project]] and [[#Local]]"
        let links = NotebookLinkParser.parse(text)
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].destination, "Projects/Überblick#Next steps")
        XCTAssertEqual(links[0].label, "the project")
        XCTAssertEqual(links[0].kind, .wiki)
        XCTAssertEqual(links[0].range.location, 3)
        XCTAssertEqual((text as NSString).substring(with: links[0].destinationRange), links[0].destination)
        XCTAssertEqual((text as NSString).substring(with: links[0].range), "[[Projects/Überblick#Next steps|the project]]")
    }

    func testMarkdownBalancedParenthesesAnglesAndTitles() {
        let text = #"[a [nested] label](../Project\(draft\).md#Next%20steps "Title") [other](<Folder/My Note.md>) [balanced](Draft(v2).md)"#
        let links = NotebookLinkParser.parse(text)
        XCTAssertEqual(links.map(\.destination), [#"../Project\(draft\).md#Next%20steps"#, "Folder/My Note.md", "Draft(v2).md"])
        XCTAssertEqual(links[0].label, "a [nested] label")
        XCTAssertEqual((text as NSString).substring(with: links[0].range), #"[a [nested] label](../Project\(draft\).md#Next%20steps "Title")"#)
    }

    func testCodeCommentsFrontmatterAndEscapesAreExcluded() {
        let text = #"""
        ---
        related: [[Frontmatter]]
        ---
        [[Visible]]
        `[[Inline]]` and ``code ` [[Also inline]]``
        \[[Escaped]]
        <!-- [[Comment]]
        [[More comment]] -->
        ```markdown
        [[Fence]]
        ```
            [[Indented]]
        ~~~
        [[Other fence]]
        ~~~
        [Visible Markdown](Visible.md)
        """#
        XCTAssertEqual(NotebookLinkParser.parse(text).map(\.destination), ["Visible", "Visible.md"])
    }

    func testEmbedsAreIdentifiedAndUnsupported() {
        let source = NotebookLinkNote(id: UUID(), name: "Source.md", path: "")
        for link in NotebookLinkParser.parse("![[Target]] ![picture](picture.png)") {
            XCTAssertTrue(link.isEmbed)
            XCTAssertEqual(NotebookLinkResolver.resolve(link, sourceID: source.id, notes: [source]), .unsupported)
        }
    }

    func testResolverRelativePathsPercentEscapesAndFragments() {
        let source = NotebookLinkNote(id: UUID(), name: "Source.md", path: "Meetings/Weekly")
        let target = NotebookLinkNote(id: UUID(), name: "Über view.md", path: "Projects")
        let link = NotebookLinkParser.parse("[read](../../Projects/%C3%9Cber%20view.md#Next%20steps)")[0]
        XCTAssertEqual(NotebookLinkResolver.resolve(link, sourceID: source.id, notes: [source, target]), .resolved(noteID: target.id, fragment: "Next steps"))
        let selfLink = NotebookLinkParser.parse("[[#^decision-1]]")[0]
        XCTAssertEqual(NotebookLinkResolver.resolve(selfLink, sourceID: source.id, notes: [source, target]), .resolved(noteID: source.id, fragment: "^decision-1"))
    }

    func testScopedRootsAndDuplicateTitlesNeverGuess() {
        let firstRoot = UUID()
        let otherRoot = UUID()
        let source = NotebookLinkNote(id: UUID(), name: "Source.md", path: "Vault A", rootID: firstRoot, rootPath: "Vault A")
        let alpha = NotebookLinkNote(id: UUID(), name: "Alpha.md", path: "Vault A/Projects", rootID: firstRoot, rootPath: "Vault A")
        let duplicate = NotebookLinkNote(id: UUID(), name: "Alpha.md", path: "Vault A/Archive", rootID: firstRoot, rootPath: "Vault A")
        let other = NotebookLinkNote(id: UUID(), name: "Alpha.md", path: "Vault B/Projects", rootID: otherRoot, rootPath: "Vault B")
        let notes = [source, alpha, duplicate, other]
        XCTAssertEqual(NotebookLinkResolver.resolve(NotebookLinkParser.parse("[[Projects/Alpha]]")[0], sourceID: source.id, notes: notes), .resolved(noteID: alpha.id, fragment: nil))
        let ambiguous = NotebookLinkResolver.resolve(NotebookLinkParser.parse("[[Alpha]]")[0], sourceID: source.id, notes: notes)
        guard case .ambiguous(let ids) = ambiguous else { return XCTFail("Expected ambiguity") }
        XCTAssertEqual(Set(ids), [alpha.id, duplicate.id])
        XCTAssertEqual(NotebookLinkResolver.resolve(NotebookLinkParser.parse("[across](../Vault%20B/Projects/Alpha.md)")[0], sourceID: source.id, notes: notes), .resolved(noteID: other.id, fragment: nil))
    }

    func testMissingExternalAttachmentsAndEscapedDestinations() {
        let source = NotebookLinkNote(id: UUID(), name: "Source.md", path: "")
        let target = NotebookLinkNote(id: UUID(), name: "Project(draft).md", path: "")
        func resolve(_ text: String) -> NotebookLinkResolution {
            NotebookLinkResolver.resolve(NotebookLinkParser.parse(text)[0], sourceID: source.id, notes: [source, target])
        }
        XCTAssertEqual(resolve("[[Unknown]]"), .missing(destination: "Unknown"))
        XCTAssertEqual(resolve("[website](https://example.com/path#section)"), .external(URL(string: "https://example.com/path#section")!))
        XCTAssertEqual(resolve("[[diagram.png]]"), .unsupported)
        XCTAssertEqual(resolve("[pdf](Guide.pdf)"), .unsupported)
        XCTAssertEqual(resolve(#"[draft](Project\(draft\).md)"#), .resolved(noteID: target.id, fragment: nil))
    }

    func testWikiExternalFallbackDoesNotTakeOverLocalColonNames() {
        let source = NotebookLinkNote(id: UUID(), name: "Source.md", path: "")
        let target = NotebookLinkNote(id: UUID(), name: "mailto:local.md", path: "")
        let lookup = NotebookLinkResolver.Lookup(notes: [source, target])
        let local = NotebookLinkParser.parse("[[mailto:local]]")[0]
        XCTAssertEqual(lookup.resolve(local, sourceID: source.id),
                       .resolved(noteID: target.id, fragment: nil))
        for raw in ["http://example.com", "https://example.com/path#part", "mailto:local"] {
            let markdown = NotebookLinkParser.parse("[explicit](\(raw))")[0]
            XCTAssertEqual(lookup.resolve(markdown, sourceID: source.id),
                           .external(URL(string: raw)!))
        }
        for raw in ["http://example.com", "https://example.com/path#part", "mailto:other@example.com"] {
            let wiki = NotebookLinkParser.parse("[[\(raw)]]")[0]
            XCTAssertEqual(lookup.resolve(wiki, sourceID: source.id),
                           .external(URL(string: raw)!))
        }
        for raw in ["custom:missing", "javascript:alert(1)", "file:/private/unknown"] {
            let wiki = NotebookLinkParser.parse("[[\(raw)]]")[0]
            XCTAssertEqual(lookup.resolve(wiki, sourceID: source.id),
                           .missing(destination: raw))
        }
    }

    func testHeadingAndExistingBlockTargets() {
        let text = """
        # Overview
        ## Next steps
        A decision. ^decision-1
        ### Detail
        ```
        # Fake heading
        ```
        Setext title
        ------------
        """
        let ns = text as NSString
        let heading = NotebookLinkParser.targetRange(for: "Next%20steps", in: text)
        XCTAssertEqual(heading.map { ns.substring(with: $0) }, "## Next steps")
        XCTAssertNotNil(NotebookLinkParser.targetRange(for: "next-steps", in: text))
        XCTAssertNotNil(NotebookLinkParser.targetRange(for: "Overview#Next steps#Detail", in: text))
        let block = NotebookLinkParser.targetRange(for: "^decision-1", in: text)
        XCTAssertEqual(block.map { ns.substring(with: $0) }, "A decision. ^decision-1")
        XCTAssertNil(NotebookLinkParser.targetRange(for: "Fake heading", in: text))
        XCTAssertNotNil(NotebookLinkParser.targetRange(for: "Setext title", in: text))
    }

    func testBacklinksContainOccurrencesButExcludeSelfAndEmbeds() {
        let target = NotebookLinkNote(id: UUID(), name: "Target.md", path: "")
        let source = NotebookLinkNote(id: UUID(), name: "Source.md", path: "")
        let text = "Read [[Target]].\nSee [again](Target.md#Next). ![[Target]]"
        let index = NotebookLinkIndex(texts: [source.id: text, target.id: "[[#Local]]"], notes: [source, target])
        let incoming = index.backlinks(to: target.id)
        XCTAssertEqual(incoming.count, 2)
        XCTAssertEqual(Set(incoming.map(\.sourceID)), [source.id])
        XCTAssertEqual(incoming[0].snippet, "Read [[Target]].")
        XCTAssertEqual((text as NSString).substring(with: incoming[1].occurrence.range), "[again](Target.md#Next)")
    }

    func testEscapedFragmentsAndCodeInLabels() {
        let source = NotebookLinkNote(id: UUID(), name: "Source.md", path: "")
        let target = NotebookLinkNote(id: UUID(), name: "Part#One.md", path: "")
        let links = NotebookLinkParser.parse(##"[[Part\#One|`label`]] [a `code ]` label](Part%23One.md)"##)
        XCTAssertEqual(links.count, 2)
        for link in links {
            XCTAssertEqual(NotebookLinkResolver.resolve(link, sourceID: source.id, notes: [source, target]), .resolved(noteID: target.id, fragment: nil))
        }
    }

    func testNestedHeadingsStayInsideTheirParentSection() {
        let text = "# First\n## Child\n# Second\n## Other"
        XCTAssertNil(NotebookLinkParser.targetRange(for: "First#Other", in: text))
        XCTAssertNotNil(NotebookLinkParser.targetRange(for: "Second#Other", in: text))
    }

    func testMarkdownRootPathsAndConflictingRelativePaths() {
        let rootID = UUID()
        let source = NotebookLinkNote(id: UUID(), name: "Source.md", path: "Vault/Meetings", rootID: rootID, rootPath: "Vault")
        let rootTarget = NotebookLinkNote(id: UUID(), name: "X.md", path: "Vault/Projects", rootID: rootID, rootPath: "Vault")
        let localTarget = NotebookLinkNote(id: UUID(), name: "X.md", path: "Vault/Meetings/Projects", rootID: rootID, rootPath: "Vault")
        let link = NotebookLinkParser.parse("[x](Projects/X.md)")[0]
        XCTAssertEqual(NotebookLinkResolver.resolve(link, sourceID: source.id, notes: [source, rootTarget]), .resolved(noteID: rootTarget.id, fragment: nil))
        guard case .ambiguous(let ids) = NotebookLinkResolver.resolve(link, sourceID: source.id, notes: [source, rootTarget, localTarget]) else { return XCTFail("Expected ambiguity") }
        XCTAssertEqual(Set(ids), [rootTarget.id, localTarget.id])
        let explicit = NotebookLinkParser.parse("[x](./Projects/X.md)")[0]
        XCTAssertEqual(NotebookLinkResolver.resolve(explicit, sourceID: source.id, notes: [source, rootTarget, localTarget]), .resolved(noteID: localTarget.id, fragment: nil))
        let missingAsset = NotebookLinkParser.parse("[[Export.docx]]")[0]
        XCTAssertEqual(NotebookLinkResolver.resolve(missingAsset, sourceID: source.id, notes: [source]), .unsupported)
    }

    func testGeneratedDestinationsRoundTripSpecialFilenames() throws {
        let source = NotebookLinkNote(id: UUID(), name: "Source.md", path: "Notes")
        let target = NotebookLinkNote(id: UUID(), name: "A#B|C[D](E)%20.md", path: "Projects")
        for kind in [NotebookLinkKind.wiki, .markdown] {
            let destination = try XCTUnwrap(NotebookLinkDestination.make(target: target, source: source, kind: kind, includeExtension: false))
            XCTAssertFalse(destination.hasSuffix(".md"))
            let text = kind == .wiki ? "[[\(destination)|label]]" : "[label](\(destination))"
            let links = NotebookLinkParser.parse(text)
            XCTAssertEqual(links.count, 1)
            let link = try XCTUnwrap(links.first)
            XCTAssertEqual(NotebookLinkResolver.resolve(link, sourceID: source.id, notes: [source, target]), .resolved(noteID: target.id, fragment: nil))
        }
    }

    func testSelectedWikiHeadingsRoundTripDelimiterCharacters() throws {
        let source = NotebookLinkNote(id: UUID(), name: "Source.md", path: "")
        let target = NotebookLinkNote(id: UUID(), name: "Target.md", path: "")
        for heading in ["A|B", "Ends]", "C# language", "Literal %25", #"Back\slash"#] {
            let literal = NotebookLinkDestination.wikiHeadingFragment(heading)
            let destination = try XCTUnwrap(NotebookLinkDestination.make(
                target: target, source: source, kind: .wiki,
                fragment: literal, includeExtension: false))
            let text = "[[\(destination)]]"
            let links = NotebookLinkParser.parse(text)
            XCTAssertEqual(links.count, 1, heading)
            let link = try XCTUnwrap(links.first)
            XCTAssertEqual(link.range, NSRange(location: 0, length: text.utf16.count), heading)
            XCTAssertNil(link.label, heading)
            let fragment = try XCTUnwrap(NotebookLinkResolver.fragment(of: link))
            XCTAssertEqual(fragment, heading)
            XCTAssertEqual(NotebookLinkResolver.resolve(link, sourceID: source.id,
                notes: [source, target]), .resolved(noteID: target.id, fragment: heading))
            let targetText = "# \(heading)\nFictional heading content"
            let range = try XCTUnwrap(NotebookLinkParser.targetRange(for: fragment, in: targetText))
            XCTAssertEqual((targetText as NSString).substring(with: range), "# \(heading)")
        }
    }

    func testLiteralHeadingTitlePrecedesNestedHeadingFallback() throws {
        let text = "# C\n## language\n# C#language\n# Other\n## Detail"
        let literalRange = try XCTUnwrap(NotebookLinkParser.targetRange(for: "C#language", in: text))
        XCTAssertEqual((text as NSString).substring(with: literalRange), "# C#language")
        let nestedRange = try XCTUnwrap(NotebookLinkParser.targetRange(for: "Other#Detail", in: text))
        XCTAssertEqual((text as NSString).substring(with: nestedRange), "## Detail")
    }

    func testGeneratedMarkdownFragmentsStayValidAndPreserveEscapes() throws {
        let source = NotebookLinkNote(id: UUID(), name: "Source.md", path: "")
        let target = NotebookLinkNote(id: UUID(), name: "Target.md", path: "")
        for fragment in ["Next steps (today)", "Next%20steps", #"Next \(today\)"#] {
            let destination = try XCTUnwrap(NotebookLinkDestination.make(target: target, source: source, kind: .markdown, fragment: fragment))
            let links = NotebookLinkParser.parse("[read](\(destination))")
            XCTAssertEqual(links.count, 1)
            let link = try XCTUnwrap(links.first)
            let expected = fragment == "Next%20steps" ? "Next steps" : "Next steps (today)"
            let resolvedFragment = NotebookLinkResolver.fragment(of: link)
            if fragment.contains("\\") { XCTAssertEqual(resolvedFragment, "Next (today)") }
            else { XCTAssertEqual(resolvedFragment, expected) }
        }
    }

    func testCommentsInCodeAndUnclosedFrontmatterStayLiteral() {
        XCTAssertEqual(NotebookLinkParser.parse("`<!--` [[Visible]]").map(\.destination), ["Visible"])
        XCTAssertEqual(NotebookLinkParser.parse("<!-- ` --> [[Visible]] `").map(\.destination), ["Visible"])
        XCTAssertEqual(NotebookLinkParser.parse("---\n[[Visible]]").map(\.destination), ["Visible"])
        XCTAssertEqual(NotebookLinkParser.parse("`unclosed\n\n[[Visible]]\n` ").map(\.destination), ["Visible"])
    }

    func testHeadingSuggestionsShareNavigationExclusionsAndHierarchy() {
        let text = """
        ---
        title: heading metadata
        ---
        # **Overview**
        ## Next steps
        ## snake_case
        <!--
        # Hidden
        -->
        ```
        # Code
        ```
        Setext
        ======
        """
        let headings = NotebookLinkParser.headings(in: text)
        XCTAssertEqual(headings, ["Overview", "Next steps", "Overview#Next steps", "snake_case", "Overview#snake_case", "Setext"])
        for heading in headings { XCTAssertNotNil(NotebookLinkParser.targetRange(for: heading, in: text)) }
    }

    func testFrontmatterAliasFlowListsSupportQuotedCommasAndComments() {
        let text = """
        ---
        aliases: [Project Alpha, "Alias, with comma", 'Bob''s name', "Hash # tag"] # comment
        ---
        body
        """
        XCTAssertEqual(NotebookLinkParser.aliases(in: text), ["Project Alpha", "Alias, with comma", "Bob's name", "Hash # tag"])
        XCTAssertEqual(NotebookLinkParser.aliases(in: "aliases: [Outside frontmatter]"), [])
        XCTAssertEqual(NotebookLinkParser.aliases(in: "---\naliases: [Unclosed]"), [])
    }

    func testFrontmatterAliasBlockListsStopAtOtherProperties() {
        let text = """
        ---
        aliases:
          - "First"
          - 'Second'
          - First # duplicate
        tags:
          - ignored
        ---
        aliases: [Body]
        """
        XCTAssertEqual(NotebookLinkParser.aliases(in: text), ["First", "Second"])
        XCTAssertEqual(NotebookLinkParser.aliases(in: "---\naliases: 'Legacy alias'\n---"), ["Legacy alias"])
        XCTAssertEqual(NotebookLinkParser.aliases(in: "---\nproperties:\n  aliases: [Nested]\n---"), [])
    }

    func testIncompleteLinksAreOnlyAvailableForPresentation() {
        let text = "[draft](https://example.com/path\n[[Complete]]"
        XCTAssertEqual(NotebookLinkParser.parse(text).map(\.destination), ["Complete"])
        let painted = NotebookLinkParser.parse(text, includingIncomplete: true)
        XCTAssertEqual(painted.map(\.destination), ["https://example.com/path", "Complete"])
        XCTAssertEqual((text as NSString).substring(with: painted[0].range), "[draft](https://example.com/path")
    }

    func testMalformedLinksStayLiteral() {
        XCTAssertEqual(NotebookLinkParser.parse("[[Unclosed] [broken](No close [bad](<angle)"), [])
        XCTAssertEqual(NotebookLinkParser.parse("`unfinished [[Actual]]").map(\.destination), ["Actual"])
    }
}
