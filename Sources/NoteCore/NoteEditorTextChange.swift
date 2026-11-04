import Foundation

/// A native replacement in the UTF-16 coordinates of the displayed revision.
/// The session verifies this hint against its cached source before using it.
public struct NoteEditorTextChange: Sendable, Equatable {
    public let range: NSRange
    public let replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }

    func validatedScalarRange(
        in source: String, resultingIn text: String
    ) throws -> (start: UInt64, length: UInt64)? {
        let (lower, upper) = try AutomergeTextIndex.scalarBounds(
            forUTF16Range: range, in: source
        )
        // Compare literal bytes: the text before the edit, the replacement,
        // and the text after it. Both ends fall between scalars, so equal
        // bytes mean equal UTF-16 units. This also permits edits inside a
        // composed grapheme.
        let sourceUTF8 = source.utf8
        let prefix = sourceUTF8.distance(from: sourceUTF8.startIndex, to: lower)
        let removed = sourceUTF8.distance(from: lower, to: upper)
        let inserted = replacement.utf8.count
        guard text.utf8.count == source.utf8.count - removed + inserted,
              Self.bytes(of: source, in: 0..<prefix, equal: text, at: 0),
              Self.bytes(of: replacement, in: 0..<inserted, equal: text, at: prefix),
              Self.bytes(
                  of: source, in: (prefix + removed)..<source.utf8.count,
                  equal: text, at: prefix + inserted
              ) else { return nil }
        return AutomergeTextIndex.scalarRange(from: lower, to: upper, in: source)
    }

    private static func bytes(
        of source: String, in range: Range<Int>, equal text: String, at offset: Int
    ) -> Bool {
        guard !range.isEmpty else { return true }
        let compared = source.utf8.withContiguousStorageIfAvailable { sourceBytes in
            text.utf8.withContiguousStorageIfAvailable { textBytes in
                memcmp(
                    sourceBytes.baseAddress! + range.lowerBound,
                    textBytes.baseAddress! + offset, range.count
                ) == 0
            }
        }
        if let compared = compared ?? nil { return compared }
        return source.utf8.dropFirst(range.lowerBound).prefix(range.count)
            .elementsEqual(text.utf8.dropFirst(offset).prefix(range.count))
    }
}

extension String {
    /// Literal UTF-8 equality, unlike `==`, which treats canonically
    /// equivalent text as equal. The editor compares whole notes on every
    /// keystroke, so it answers from the stored byte counts or a shared
    /// buffer when it can, and only otherwise compares every byte.
    public func literallyEquals(_ other: String) -> Bool {
        guard utf8.count == other.utf8.count else { return false }
        let sharesBuffer = utf8.withContiguousStorageIfAvailable { bytes in
            other.utf8.withContiguousStorageIfAvailable {
                bytes.baseAddress == $0.baseAddress
            } ?? false
        } ?? false
        return sharesBuffer || utf8.elementsEqual(other.utf8)
    }
}
