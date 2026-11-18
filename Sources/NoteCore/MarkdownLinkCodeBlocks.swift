import Foundation
import cmark_gfm

/// The CommonMark block pass supplies source lines only. Link spelling,
/// UTF-16 destination ranges, and app-specific syntax stay in NoteCore.
public struct MarkdownLinkCodeBlock: Equatable, Sendable {
    public let range: NSRange
    public let isFenced: Bool
    public let isUnclosedAtEnd: Bool

    public init(range: NSRange, isFenced: Bool, isUnclosedAtEnd: Bool) {
        self.range = range
        self.isFenced = isFenced
        self.isUnclosedAtEnd = isUnclosedAtEnd
    }
}

extension NotebookLinkParser {
    public static func codeBlocks(
        in text: String, allowFrontmatter: Bool = true
    ) -> [MarkdownLinkCodeBlock] {
        let frontmatter = allowFrontmatter ? frontmatterRange(in: text as NSString) : nil
        return codeBlocks(in: text, after: frontmatter)
    }

    static func codeBlocks(
        in text: String, after frontmatter: NSRange?
    ) -> [MarkdownLinkCodeBlock] {
        let offset = frontmatter.map(NSMaxRange) ?? 0
        var body = offset == 0 ? text : (text as NSString).substring(from: offset)
        // Every block fence has three matching markers. An indented
        // block needs four spaces or a tab, including inside containers.
        guard body.withUTF8(mayContainCodeBlock) else { return [] }
        var input = body.withUTF8(hasLongFenceRun) ? compactLongFenceRuns(in: body) : body
        let document = input.withUTF8 { bytes in
            return bytes.withMemoryRebound(to: CChar.self) {
                cmark_parse_document($0.baseAddress, $0.count, CMARK_OPT_DEFAULT)
            }
        }
        guard let document else { return [] }
        defer { cmark_node_free(document) }

        var codeNodes: [UnsafeMutablePointer<cmark_node>] = []
        collectCodeBlocks(in: document, into: &codeNodes)
        guard !codeNodes.isEmpty else { return [] }
        let lineStarts = codeBlockLineStarts(in: body)
        let lastLine = lineStarts.count - 1
        let lastContentLine = lineStarts[lastLine] == body.utf16.count ? lastLine - 1 : lastLine

        return codeNodes.map { node in
            let first = Int(cmark_node_get_start_line(node)) - 1
            // An unclosed fence inside a list or quote can report one extra
            // line when its container ends. That line belongs to the next block.
            let parentEnd = cmark_node_get_end_line(cmark_node_parent(node))
            let last = min(Int(min(cmark_node_get_end_line(node), parentEnd)) - 1, lastContentLine)
            let end = last < lastLine ? lineStarts[last + 1] : body.utf16.count
            var length: CInt = 0
            var indentation: CInt = 0
            var marker: CChar = 0
            let fenced = cmark_node_get_fenced(node, &length, &indentation, &marker) == 1
            // The literal has one LF per source body line, including when
            // CommonMark normalizes a missing final line break.
            let unclosed = fenced && last == lastContentLine
                && codeBodyLineCount(of: node) == last - first
            return MarkdownLinkCodeBlock(
                range: NSRange(location: offset + lineStarts[first],
                               length: end - lineStarts[first]),
                isFenced: fenced,
                isUnclosedAtEnd: unclosed
            )
        }
    }

    private static func mayContainCodeBlock(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        for index in bytes.indices {
            switch bytes[index] {
            case 9: return true
            case 32 where index + 3 < bytes.count:
                if bytes[index + 1] == 32, bytes[index + 2] == 32, bytes[index + 3] == 32 {
                    return true
                }
            case 96, 126:
                if index + 2 < bytes.count, bytes[index + 1] == bytes[index],
                   bytes[index + 2] == bytes[index] { return true }
            default: break
            }
        }
        return false
    }

    private static let fenceRuns = try! NSRegularExpression(pattern: "`{3,}|~{3,}")

    private static func hasLongFenceRun(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard bytes.count >= 256 else { return false }
        for index in 0...(bytes.count - 256) {
            let marker = bytes[index]
            if (marker == 96 || marker == 126), bytes[index + 255] == marker,
               bytes[(index + 1)..<(index + 255)].allSatisfy({ $0 == marker }) {
                return true
            }
        }
        return false
    }

    private static func compactLongFenceRuns(in text: String) -> String {
        let source = text as NSString
        // cmark stores the opening length in one byte. Compress distinct
        // lengths in order before parsing so a shorter fence cannot close a
        // longer one. Only source line numbers are read from cmark.
        let result = NSMutableString(string: text)
        let runs = fenceRuns.matches(in: text, range: NSRange(location: 0, length: source.length))
        var compactLengths: [unichar: [Int: Int]] = [:]
        for marker: unichar in [96, 126] {
            let matching = runs.filter { source.character(at: $0.range.location) == marker }
            let lengths = Set(matching.map { $0.range.length }).sorted()
            if lengths.count <= 253, let longest = lengths.last, longest > 255 {
                compactLengths[marker] = Dictionary(uniqueKeysWithValues: zip(lengths, 3...255))
            }
        }
        for match in runs.reversed() {
            let range = match.range
            let marker = source.character(at: range.location)
            if let count = compactLengths[marker]?[range.length], count != range.length {
                let character = marker == 96 ? "`" : "~"
                result.replaceCharacters(in: range, with: String(repeating: character, count: count))
            }
        }
        return result as String
    }

    private static func collectCodeBlocks(
        in document: UnsafeMutablePointer<cmark_node>, into codeNodes: inout [UnsafeMutablePointer<cmark_node>]
    ) {
        // Visit block children only. Paragraph inlines cannot contain blocks.
        var current = cmark_node_first_child(document)
        while let node = current {
            switch cmark_node_get_type(node) {
            case CMARK_NODE_CODE_BLOCK:
                codeNodes.append(node)
            case CMARK_NODE_LIST, CMARK_NODE_ITEM, CMARK_NODE_BLOCK_QUOTE:
                if let child = cmark_node_first_child(node) {
                    current = child
                    continue
                }
            default: break
            }
            var sibling = cmark_node_next(node)
            var parent = cmark_node_parent(node)
            while sibling == nil, let container = parent, container != document {
                sibling = cmark_node_next(container)
                parent = cmark_node_parent(container)
            }
            current = sibling
        }
    }

    private static func codeBlockLineStarts(in text: String) -> [Int] {
        var starts = [0]
        var offset = 0
        var afterCR = false
        for unit in text.utf16 {
            offset += 1
            if unit == 10, afterCR {
                starts[starts.count - 1] = offset
            } else if unit == 10 || unit == 13 {
                starts.append(offset)
            }
            afterCR = unit == 13
        }
        return starts
    }

    private static func codeBodyLineCount(of node: UnsafeMutablePointer<cmark_node>) -> Int {
        guard var byte = cmark_node_get_literal(node) else { return 0 }
        var count = 0
        while byte.pointee != 0 {
            if byte.pointee == 10 { count += 1 }
            byte += 1
        }
        return count
    }
}
