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
        guard range.location != NSNotFound else {
            throw AutomergeTextIndexError.invalidUTF16Range(range)
        }

        let (upperBound, overflow) = range.location.addingReportingOverflow(
            range.length
        )
        let codeUnits = Array(text.utf16)
        guard !overflow,
              range.location >= 0,
              range.length >= 0,
              upperBound <= codeUnits.count,
              isScalarBoundary(range.location, in: codeUnits),
              isScalarBoundary(upperBound, in: codeUnits) else {
            throw AutomergeTextIndexError.invalidUTF16Range(range)
        }

        let start = scalarCount(beforeUTF16Offset: range.location, in: codeUnits)
        let end = scalarCount(beforeUTF16Offset: upperBound, in: codeUnits)
        return (UInt64(start), UInt64(end - start))
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

    private static func isScalarBoundary(
        _ offset: Int,
        in codeUnits: [UInt16]
    ) -> Bool {
        guard offset > 0, offset < codeUnits.count else { return true }
        return !UTF16.isLeadSurrogate(codeUnits[offset - 1])
            || !UTF16.isTrailSurrogate(codeUnits[offset])
    }

    private static func scalarCount(
        beforeUTF16Offset offset: Int,
        in codeUnits: [UInt16]
    ) -> Int {
        var count = 0
        var codeUnitOffset = 0
        while codeUnitOffset < offset {
            if UTF16.isLeadSurrogate(codeUnits[codeUnitOffset]) {
                codeUnitOffset += 2
            } else {
                codeUnitOffset += 1
            }
            count += 1
        }
        return count
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
