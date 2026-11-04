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
        let scalarRange = try AutomergeTextIndex.unicodeScalarRange(
            forUTF16Range: range, in: source
        )
        // Compare literal code units without reconstructing a Foundation
        // string and transcoding its entire foreign UTF-8 view. Scalar-boundary
        // validation above also permits edits inside a composed grapheme.
        var sourceUnits = source.utf16.makeIterator()
        var resultUnits = text.utf16.makeIterator()
        for _ in 0..<range.location {
            guard sourceUnits.next() == resultUnits.next() else { return nil }
        }
        for _ in 0..<range.length { _ = sourceUnits.next() }
        for unit in replacement.utf16 {
            guard resultUnits.next() == unit else { return nil }
        }
        while let unit = sourceUnits.next() {
            guard resultUnits.next() == unit else { return nil }
        }
        guard resultUnits.next() == nil else { return nil }
        return scalarRange
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
