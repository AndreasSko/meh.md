import Foundation

public enum AutomergeTextIndexError: Error, Equatable {
    case invalidUTF16Range(NSRange)
    case invalidUnicodeScalarRange(start: UInt64, length: UInt64)
}

public enum AutomergeTextIndex {
    public static func unicodeScalarRange(
        forUTF16Range range: NSRange,
        in text: String
    ) throws -> (start: UInt64, length: UInt64) {
        let (lower, upper) = try scalarBounds(forUTF16Range: range, in: text)
        return scalarRange(from: lower, to: upper, in: text)
    }

    /// Both ends of a UTF-16 range, which must fall between scalars. Indexing
    /// the string directly avoids copying a whole note into UTF-16 per edit.
    static func scalarBounds(
        forUTF16Range range: NSRange,
        in text: String
    ) throws -> (lower: String.Index, upper: String.Index) {
        let (upperBound, overflow) = range.location.addingReportingOverflow(
            range.length
        )
        let utf16 = text.utf16
        guard range.location != NSNotFound,
              !overflow,
              range.location >= 0,
              range.length >= 0,
              upperBound <= utf16.count else {
            throw AutomergeTextIndexError.invalidUTF16Range(range)
        }
        let lower = utf16.index(utf16.startIndex, offsetBy: range.location)
        let upper = utf16.index(lower, offsetBy: range.length)
        guard let lower = lower.samePosition(in: text.unicodeScalars),
              let upper = upper.samePosition(in: text.unicodeScalars) else {
            throw AutomergeTextIndexError.invalidUTF16Range(range)
        }
        return (lower, upper)
    }

    static func scalarRange(
        from lower: String.Index,
        to upper: String.Index,
        in text: String
    ) -> (start: UInt64, length: UInt64) {
        let utf8 = text.utf8
        let lowerOffset = utf8.distance(from: utf8.startIndex, to: lower)
        let upperOffset = utf8.distance(from: utf8.startIndex, to: upper)
        if let counts = utf8.withContiguousStorageIfAvailable({ bytes in
            (scalarCount(bytes[..<lowerOffset]),
             scalarCount(bytes[lowerOffset..<upperOffset]))
        }) {
            return (UInt64(counts.0), UInt64(counts.1))
        }
        let scalars = text.unicodeScalars
        let start = scalars.distance(from: scalars.startIndex, to: lower)
        return (UInt64(start), UInt64(scalars.distance(from: lower, to: upper)))
    }

    /// Each scalar starts with exactly one byte that is not a UTF-8
    /// continuation byte. Counting those is far faster than decoding.
    private static func scalarCount(
        _ bytes: Slice<UnsafeBufferPointer<UInt8>>
    ) -> Int {
        var count = 0
        for byte in bytes where byte & 0xC0 != 0x80 { count += 1 }
        return count
    }

    public static func utf16Range(
        forUnicodeScalarStart start: UInt64,
        length: UInt64,
        in text: String
    ) throws -> NSRange {
        let (end, overflow) = start.addingReportingOverflow(length)
        let scalarCount = UInt64(text.unicodeScalars.count)
        guard !overflow, end <= scalarCount else {
            throw AutomergeTextIndexError.invalidUnicodeScalarRange(
                start: start,
                length: length
            )
        }

        let startOffset = utf16Offset(
            forUnicodeScalarOffset: Int(start),
            in: text
        )
        let endOffset = utf16Offset(
            forUnicodeScalarOffset: Int(end),
            in: text
        )
        return NSRange(location: startOffset, length: endOffset - startOffset)
    }

    private static func utf16Offset(
        forUnicodeScalarOffset target: Int,
        in text: String
    ) -> Int {
        text.unicodeScalars.prefix(target).reduce(into: 0) { result, scalar in
            result += scalar.value > 0xFFFF ? 2 : 1
        }
    }
}
