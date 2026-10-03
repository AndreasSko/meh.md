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
        let reconstructed = (source as NSString).replacingCharacters(
            in: range, with: replacement
        )
        guard reconstructed.utf8.elementsEqual(text.utf8) else { return nil }
        return scalarRange
    }
}
