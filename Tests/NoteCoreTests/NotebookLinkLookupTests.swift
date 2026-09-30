import Foundation
import XCTest

@testable import NoteCore

final class NotebookLinkLookupTests: XCTestCase {
    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value + 1))!
    }

    func testLookupMatchesScannerAcrossCurrentAndHistoricalScopes() {
        let firstRoot = id(90), secondRoot = id(91)
        let notes = [
            NotebookLinkNote(id: id(0), name: "Source.md", path: "Second/Sub",
                rootID: secondRoot, rootPath: "Second", formerLocations: [
                    .init(name: "Old source.md", path: "First/Sub", rootID: firstRoot, rootPath: "First"),
                    .init(name: "Old source.md", path: "Moved/Sub", rootID: firstRoot, rootPath: "Moved")
                ]),
            NotebookLinkNote(id: id(1), name: "Target.md", path: "First/Sub",
                rootID: firstRoot, rootPath: "First", formerLocations: [
                    .init(name: "Budget 2026.10", path: "Moved/Sub", rootID: firstRoot, rootPath: "Moved"),
                    .init(name: "Old target.md", path: "First/Sub", rootID: firstRoot, rootPath: "First")
                ]),
            NotebookLinkNote(id: id(2), name: "Target.md", path: "Second/Sub",
                rootID: secondRoot, rootPath: "Second"),
            NotebookLinkNote(id: id(3), name: "Old target.md", path: "First/Sub",
                rootID: firstRoot, rootPath: "First"),
            NotebookLinkNote(id: id(4), name: "Duplicate.md", path: "Second/Archive",
                rootID: secondRoot, rootPath: "Second"),
            NotebookLinkNote(id: id(5), name: "Duplicate.markdown", path: "Second/Sub",
                rootID: secondRoot, rootPath: "Second"),
            NotebookLinkNote(id: id(6), name: "Über view.md", path: "Projects", formerLocations: [
                .init(name: "U\u{0308}ber view.md", path: "Projects")
            ]),
            NotebookLinkNote(id: id(7), name: "Source.md", path: "", formerLocations: [
                .init(name: "Source.md", path: "", rootPath: "")
            ]),
            // Duplicate descriptors for one stable ID must deduplicate targets
            // while source selection continues to use the first descriptor.
            NotebookLinkNote(id: id(6), name: "Über view.md", path: "Other")
        ]
        let examples = [
            "[[Target]]", "[[Old target]]", "[[Budget 2026.10]]", "[[Duplicate]]",
            "[[Sub/Target#Heading]]", "[[First/Sub/Target]]", "[[./Target.md]]",
            "[same folder](./Target.md)", "[root path](Sub/Target.md)",
            "[absolute](/First/Sub/Target.md)", "[old](../../Moved/Sub/Budget%202026.10.md)",
            "[unicode](../../Projects/%C3%9Cber%20view.md#A%20heading)",
            "[[Projects/Über view#^block]]", "[[#Heading]]", "[self](#^block)",
            "[[Source]]", "[[Old source]]", "[self path](./Source.md)",
            "[[Missing]]", "[[Missing.png]]", "[asset](picture.png)",
            "[external](https://example.com/path#part)", "![[Target]]",
            "![](picture.png)", "[[/../../Invalid.pdf]]"
        ]
        let lookup = NotebookLinkResolver.Lookup(notes: notes)
        for source in notes.map(\.id) + [id(100)] {
            for text in examples {
                let occurrence = NotebookLinkParser.parse(text)[0]
                XCTAssertEqual(lookup.resolve(occurrence, sourceID: source),
                    Self.scanResolve(occurrence, sourceID: source, notes: notes),
                    "Historical lookup differs for source \(source), \(text)")
                XCTAssertEqual(lookup.resolveCurrent(occurrence, sourceID: source),
                    Self.scanCurrent(occurrence, sourceID: source, notes: notes),
                    "Current lookup differs for source \(source), \(text)")
            }
        }
    }

    func testWikiColonNamesIntentionallyDifferFromFrozenScanner() {
        let source = NotebookLinkNote(id: id(0), name: "Source.md", path: "")
        let current = NotebookLinkNote(id: id(1), name: "Project:Alpha.md", path: "")
        let historical = NotebookLinkNote(id: id(2), name: "Renamed.md", path: "",
            formerLocations: [.init(name: "Archived:Beta.md", path: "")])
        let notes = [source, current, historical]
        let lookup = NotebookLinkResolver.Lookup(notes: notes)
        for (text, target) in [("[[Project:Alpha]]", current.id),
                               ("[[Archived:Beta#Heading]]", historical.id)] {
            let link = NotebookLinkParser.parse(text)[0]
            XCTAssertEqual(lookup.resolve(link, sourceID: source.id),
                           .resolved(noteID: target, fragment: text.contains("#") ? "Heading" : nil))
            // This is a deliberate policy correction, rather than changing
            // the frozen scanner and hiding unrelated equivalence failures.
            guard case .external = Self.scanResolve(link, sourceID: source.id, notes: notes) else {
                return XCTFail("The old scanner must demonstrate the colon URL misclassification")
            }
        }
        let reused = NotebookLinkNote(id: id(3), name: "Archived:Beta.md", path: "")
        let ambiguousLookup = NotebookLinkResolver.Lookup(notes: notes + [reused])
        let ambiguous = NotebookLinkParser.parse("[[Archived:Beta]]")[0]
        XCTAssertEqual(ambiguousLookup.resolve(ambiguous, sourceID: source.id),
                       .ambiguous([historical.id, reused.id]))
        XCTAssertEqual(ambiguousLookup.resolveCurrent(ambiguous, sourceID: source.id),
                       .resolved(noteID: reused.id, fragment: nil))
        let unknown = NotebookLinkParser.parse("[[custom:missing]]")[0]
        XCTAssertEqual(lookup.resolve(unknown, sourceID: source.id),
                       .missing(destination: "custom:missing"))
        guard case .external = Self.scanResolve(unknown, sourceID: source.id, notes: notes) else {
            return XCTFail("Unknown wiki schemes previously opened externally")
        }
    }

    func testLookupPreservesRawRootPrefixBeforeNormalizingRelativeWikiPath() {
        let root = id(90)
        let notes = [
            NotebookLinkNote(id: id(0), name: "Source.md", path: "Before/../Vault/Sub",
                rootID: root, rootPath: "Before/../Vault", formerLocations: [
                    .init(name: "Source.md", path: "Before/./Vault/Sub", rootID: root, rootPath: "Before/./Vault")
                ]),
            NotebookLinkNote(id: id(1), name: "Target.md", path: "Before/../Vault/Sub", rootID: root),
            NotebookLinkNote(id: id(2), name: "Target.md", path: "Vault/Sub", rootID: root),
            NotebookLinkNote(id: id(3), name: "Target.md", path: "Before/./Vault/Other", rootID: root)
        ]
        let lookup = NotebookLinkResolver.Lookup(notes: notes)
        for text in ["[[Target]]", "[[Sub/Target]]", "[[Vault/Sub/Target]]", "[[./Target.md]]"] {
            let occurrence = NotebookLinkParser.parse(text)[0]
            XCTAssertEqual(lookup.resolve(occurrence, sourceID: id(0)),
                           Self.scanResolve(occurrence, sourceID: id(0), notes: notes))
        }
    }

    func testTwoThousandNotesWithTwentyThousandLinks() {
        let noteCount = 2_000, linksPerNote = 10
        let notes = (0..<noteCount).map { index in
            NotebookLinkNote(id: id(index), name: "Note \(index).md",
                path: "Vault \(index % 10)/Folder \(index % 5)",
                rootID: id(noteCount + index % 10), rootPath: "Vault \(index % 10)",
                formerLocations: [.init(name: "Old note \(index).md",
                    path: "Older \(index % 10)/Folder \(index % 5)",
                    rootID: id(noteCount + index % 10), rootPath: "Older \(index % 10)")])
        }
        var texts: [UUID: String] = [:]
        for index in 0..<noteCount {
            texts[id(index)] = (1...linksPerNote).map { offset in
                let target = (index + offset * 10) % noteCount
                return offset.isMultiple(of: 2) ? "[[Note \(target)]]"
                    : "[old](<./Old note \(target).md>)"
            }.joined(separator: "\n")
        }
        let lookupStart = Date()
        let lookup = NotebookLinkResolver.Lookup(notes: notes)
        let lookupSeconds = Date().timeIntervalSince(lookupStart)
        let sample = NotebookLinkParser.parse(texts[id(0)]!)
        let scanStart = Date()
        let expected = sample.map { Self.scanResolve($0, sourceID: id(0), notes: notes) }
        let scanSeconds = Date().timeIntervalSince(scanStart)
        let resolveStart = Date()
        XCTAssertEqual(sample.map { lookup.resolve($0, sourceID: id(0)) }, expected)
        let resolveSeconds = Date().timeIntervalSince(resolveStart)
        let indexStart = Date()
        let index = NotebookLinkIndex(texts: texts, notes: notes)
        let indexSeconds = Date().timeIntervalSince(indexStart)
        XCTAssertEqual(notes.reduce(0) { $0 + index.backlinks(to: $1.id).count },
                       noteCount * linksPerNote)
        XCTAssertTrue(notes.allSatisfy { index.backlinks(to: $0.id).count == linksPerNote })
        print(String(format:
            "LINK LOOKUP BENCHMARK: 2000 notes, 20000 links, lookup %.3fs; 10 scanner resolutions %.3fs; 10 lookup resolutions %.3fs; full index %.3fs",
            lookupSeconds, scanSeconds, resolveSeconds, indexSeconds))
    }

    // Frozen pre-lookup scanner: semantic reference independent of lookup maps.
    private static func scanResolve(_ occurrence: NotebookLinkOccurrence, sourceID: UUID,
                               notes: [NotebookLinkNote]) -> NotebookLinkResolution {
        let current = scanCurrent(occurrence, sourceID: sourceID, notes: notes)
        // A reused path has two plausible identities: the old relationship
        // and a newly authored link. Literal Markdown has no creation-time ID,
        // so include both candidates and let the user choose instead of silently
        // redirecting an existing link after a rename or source-folder move.
        switch current {
        case .external: return current
        case .unsupported where occurrence.isEmbed || occurrence.kind == .markdown:
            return current
        default: break
        }
        guard let source = notes.first(where: { $0.id == sourceID }),
              notes.contains(where: { !$0.formerLocations.isEmpty }) else {
            return current
        }
        func variants(_ note: NotebookLinkNote) -> [NotebookLinkNote] {
            ([note.location] + note.formerLocations).map {
                NotebookLinkNote(id: note.id, name: $0.name, path: $0.path,
                                 rootID: $0.rootID, rootPath: $0.rootPath)
            }
        }
        let targets = notes.filter { $0.id != sourceID }.flatMap(variants)
        var ids = Set<UUID>()
        for sourceVariant in variants(source) {
            switch scanCurrent(occurrence, sourceID: sourceID,
                                  notes: [sourceVariant] + targets) {
            case .resolved(let id, _): ids.insert(id)
            case .ambiguous(let candidates): ids.formUnion(candidates)
            default: break
            }
        }
        if ids.count == 1, let id = ids.first {
            return .resolved(noteID: id, fragment: NotebookLinkResolver.fragment(of: occurrence))
        }
        if ids.count > 1 {
            return .ambiguous(ids.sorted { $0.uuidString < $1.uuidString })
        }
        return current
    }

    /// Resolve only current locations when validating a newly authored
    /// destination. Navigation and indexing should use `resolve` so earlier
    /// relationships cannot be silently redirected by a reused path.
    private static func scanCurrent(_ occurrence: NotebookLinkOccurrence, sourceID: UUID,
                               notes: [NotebookLinkNote]) -> NotebookLinkResolution {
        guard !occurrence.isEmbed else { return .unsupported }
        let literal = occurrence.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = unescaped(literal)
        if let url = URL(string: raw), url.scheme != nil { return .external(url) }
        guard let source = notes.first(where: { $0.id == sourceID }) else { return .unsupported }
        let path = NotebookLinkResolver.path(of: occurrence)
        let fragment = NotebookLinkResolver.fragment(of: occurrence)
        if path.isEmpty { return .resolved(noteID: sourceID, fragment: fragment) }
        let ext = (path as NSString).pathExtension.lowercased()
        if occurrence.kind == .markdown && !ext.isEmpty && ext != "md" && ext != "markdown" {
            return .unsupported
        }
        let candidates: [NotebookLinkNote]
        if occurrence.kind == .markdown || path.hasPrefix("./") || path.hasPrefix("../") {
            let explicitRelative = path.hasPrefix("./") || path.hasPrefix("../")
            let absolute = path.hasPrefix("/")
            let relative = source.path.isEmpty ? path : source.path + "/" + path
            let rootRelative = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let root = source.rootPath.map { $0.isEmpty ? rootRelative : $0 + "/" + rootRelative } ?? rootRelative
            var destinations = Set<String>()
            if !absolute, let relative = normalized(relative) { destinations.insert(relative) }
            // Obsidian also writes root-based Markdown paths without a slash.
            // If both interpretations exist, let the user choose rather than guess.
            if !explicitRelative, let root = normalized(root) { destinations.insert(root) }
            candidates = notes.filter { normalized($0.fullPath).map { destinations.contains($0) } ?? false }
        } else {
            guard let wanted = normalized(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) else { return .missing(destination: raw) }
            candidates = notes.filter { note in
                guard note.rootID == source.rootID else { return false }
                var relative = note.fullPath
                if let rootPath = source.rootPath, !rootPath.isEmpty {
                    guard relative.hasPrefix(rootPath + "/") else { return false }
                    relative = String(relative.dropFirst(rootPath.count + 1))
                }
                guard let normalizedPath = normalized(relative) else { return false }
                return normalizedPath == wanted || normalizedPath.hasSuffix("/" + wanted)
            }
        }
        let candidateIDs = Set(candidates.map(\.id))
        if candidateIDs.count == 1, let id = candidateIDs.first {
            return .resolved(noteID: id, fragment: fragment)
        }
        if candidateIDs.isEmpty {
            if !ext.isEmpty && ext != "md" && ext != "markdown" { return .unsupported }
            return .missing(destination: raw)
        }
        return .ambiguous(candidateIDs.sorted { $0.uuidString < $1.uuidString })
    }

    private static func normalized(_ path: String) -> String? {
        var parts: [String] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { guard !parts.isEmpty else { return nil }; parts.removeLast() }
            else { parts.append(String(part).precomposedStringWithCanonicalMapping) }
        }
        guard !parts.isEmpty else { return "" }
        let ext = (parts[parts.count - 1] as NSString).pathExtension.lowercased()
        if ext == "md" || ext == "markdown" { parts[parts.count - 1] = (parts[parts.count - 1] as NSString).deletingPathExtension }
        return parts.joined(separator: "/")
    }

    private static func unescaped(_ value: String) -> String {
        value.replacingOccurrences(of: ##"\\([!\"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~])"##, with: "$1", options: .regularExpression)
    }
}
