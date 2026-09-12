import Foundation
import XCTest

@testable import NoteCore

final class AutomergeTextIndexTests: XCTestCase {
    func testUTF16AndScalarRangesRoundTrip() throws {
        let text = "e\u{301} 👋🏽 family 👨‍👩‍👧‍👦"
        let nativeRange = (text as NSString).range(of: "\u{301} 👋🏽")

        let scalarRange = try AutomergeTextIndex.unicodeScalarRange(
            forUTF16Range: nativeRange,
            in: text
        )
        let roundTrip = try AutomergeTextIndex.utf16Range(
            forUnicodeScalarStart: scalarRange.start,
            length: scalarRange.length,
            in: text
        )

        XCTAssertEqual(roundTrip, nativeRange)
    }

    func testRangeInsideSurrogatePairIsRejected() {
        let range = NSRange(location: 2, length: 0)

        XCTAssertThrowsError(
            try AutomergeTextIndex.unicodeScalarRange(
                forUTF16Range: range,
                in: "a😀b"
            )
        )
    }
}
