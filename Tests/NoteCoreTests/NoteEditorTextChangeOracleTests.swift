import Foundation
import XCTest

@testable import NoteCore

/// The edit check guards which text the note saves, so its faster version
/// must answer exactly like the earlier UTF-16 implementation kept below.
final class NoteEditorTextChangeOracleTests: XCTestCase {
    private let pieces = [
        "a", "Z", " ", "\n", "\r\n", "\0", "é", "e\u{301}", "ß", "€",
        "👋", "👋🏽", "👨‍👩‍👧‍👦", "🪐", "\u{FFFD}", "日本",
    ]

    func testValidationMatchesUTF16Implementation() throws {
        var random = SeededRandom(seed: 0x6d65682e6d64)
        var outcomes = (accepted: 0, rejected: 0, invalid: 0)
        for _ in 0..<20_000 {
            let source = maybeBridged(randomText(&random, maxPieces: 12), &random)
            let length = (source as NSString).length
            let range = randomRange(&random, length: length)
            let replacement = randomText(&random, maxPieces: 2)
            let text = maybeBridged(
                candidateResult(source, range, replacement, &random), &random
            )
            let change = NoteEditorTextChange(range: range, replacement: replacement)

            let expected = Result {
                try LegacyValidation.validatedScalarRange(change, in: source, resultingIn: text)
            }
            let actual = Result { try change.validatedScalarRange(in: source, resultingIn: text) }
            switch (expected, actual) {
            case let (.success(old), .success(new)):
                if old == nil { outcomes.rejected += 1 } else { outcomes.accepted += 1 }
                XCTAssertEqual(old?.start, new?.start, "\(debug(source, range, replacement, text))")
                XCTAssertEqual(old?.length, new?.length, "\(debug(source, range, replacement, text))")
                XCTAssertEqual(old == nil, new == nil, "\(debug(source, range, replacement, text))")
            case let (.failure(old), .failure(new)):
                outcomes.invalid += 1
                XCTAssertEqual(
                    old as? AutomergeTextIndexError, new as? AutomergeTextIndexError,
                    "\(debug(source, range, replacement, text))"
                )
            default:
                XCTFail("Results differ: \(expected) \(actual) \(debug(source, range, replacement, text))")
            }
        }
        XCTAssertGreaterThan(outcomes.accepted, 3_000)
        XCTAssertGreaterThan(outcomes.rejected, 3_000)
        XCTAssertGreaterThan(outcomes.invalid, 3_000)
        print("Edit check outcomes:", outcomes)
    }

    private func randomText(_ random: inout SeededRandom, maxPieces: Int) -> String {
        var units: [UInt16] = []
        for _ in 0..<random.next(upTo: maxPieces + 1) {
            if random.next(upTo: 40) == 0 {
                units.append(random.next(upTo: 2) == 0 ? 0xD83D : 0xDC4B)
            } else {
                units += pieces[random.next(upTo: pieces.count)].utf16
            }
        }
        // Foundation keeps lone surrogates; String(utf16CodeUnits:) repairs them.
        return NSString(characters: units, length: units.count) as String
    }

    private func randomRange(_ random: inout SeededRandom, length: Int) -> NSRange {
        switch random.next(upTo: 30) {
        case 0: return NSRange(location: NSNotFound, length: 0)
        case 1: return NSRange(location: -1, length: 1)
        case 2: return NSRange(location: length, length: 1)
        case 3: return NSRange(location: Int.max, length: 1)
        default:
            let location = random.next(upTo: length + 1)
            return NSRange(location: location, length: random.next(upTo: min(4, length - location) + 1))
        }
    }

    private func candidateResult(
        _ source: String, _ range: NSRange, _ replacement: String, _ random: inout SeededRandom
    ) -> String {
        let ns = source as NSString
        let valid = range.location != NSNotFound && range.location >= 0 && range.length >= 0
            && range.location <= ns.length && range.length <= ns.length - range.location
        var result = valid
            ? ns.replacingCharacters(in: range, with: replacement)
            : source + replacement
        switch random.next(upTo: 6) {
        case 0:
            result = randomText(&random, maxPieces: 12)
        case 1 where !result.isEmpty:
            var scalars = Array(result.unicodeScalars)
            scalars[random.next(upTo: scalars.count)] = "x"
            result = String(String.UnicodeScalarView(scalars))
        case 2:
            result += pieces[random.next(upTo: pieces.count)]
        case 3 where !result.isEmpty:
            result.removeLast()
        default:
            break
        }
        return result
    }

    private func maybeBridged(_ text: String, _ random: inout SeededRandom) -> String {
        random.next(upTo: 4) == 0 ? NSMutableString(string: text) as String : text
    }

    private func debug(_ source: String, _ range: NSRange, _ replacement: String, _ text: String) -> String {
        "source \(Array(source.utf16)) range \(range) replacement \(Array(replacement.utf16)) text \(Array(text.utf16))"
    }
}

private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(upTo bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(max(bound, 1)))
    }
}

/// The validation and range mapping before they compared bytes in place.
private enum LegacyValidation {
    static func validatedScalarRange(
        _ change: NoteEditorTextChange, in source: String, resultingIn text: String
    ) throws -> (start: UInt64, length: UInt64)? {
        let range = change.range
        let scalarRange = try unicodeScalarRange(forUTF16Range: range, in: source)
        var sourceUnits = source.utf16.makeIterator()
        var resultUnits = text.utf16.makeIterator()
        for _ in 0..<range.location {
            guard sourceUnits.next() == resultUnits.next() else { return nil }
        }
        for _ in 0..<range.length { _ = sourceUnits.next() }
        for unit in change.replacement.utf16 {
            guard resultUnits.next() == unit else { return nil }
        }
        while let unit = sourceUnits.next() {
            guard resultUnits.next() == unit else { return nil }
        }
        guard resultUnits.next() == nil else { return nil }
        return scalarRange
    }

    static func unicodeScalarRange(
        forUTF16Range range: NSRange, in text: String
    ) throws -> (start: UInt64, length: UInt64) {
        guard range.location != NSNotFound else {
            throw AutomergeTextIndexError.invalidUTF16Range(range)
        }
        let (upperBound, overflow) = range.location.addingReportingOverflow(range.length)
        let codeUnits = Array(text.utf16)
        guard !overflow, range.location >= 0, range.length >= 0,
              upperBound <= codeUnits.count,
              isScalarBoundary(range.location, in: codeUnits),
              isScalarBoundary(upperBound, in: codeUnits) else {
            throw AutomergeTextIndexError.invalidUTF16Range(range)
        }
        let start = scalarCount(before: range.location, in: codeUnits)
        let end = scalarCount(before: upperBound, in: codeUnits)
        return (UInt64(start), UInt64(end - start))
    }

    private static func isScalarBoundary(_ offset: Int, in codeUnits: [UInt16]) -> Bool {
        guard offset > 0, offset < codeUnits.count else { return true }
        return !UTF16.isLeadSurrogate(codeUnits[offset - 1])
            || !UTF16.isTrailSurrogate(codeUnits[offset])
    }

    private static func scalarCount(before offset: Int, in codeUnits: [UInt16]) -> Int {
        var count = 0
        var index = 0
        while index < offset {
            index += UTF16.isLeadSurrogate(codeUnits[index]) ? 2 : 1
            count += 1
        }
        return count
    }
}
