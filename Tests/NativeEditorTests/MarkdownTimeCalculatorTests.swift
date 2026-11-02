import Foundation
import XCTest

@testable import NativeEditor

@MainActor
final class MarkdownTimeCalculatorTests: XCTestCase {
    /// The formatted result of every `=` line, parsed as the editor does.
    private func results(_ text: String) -> [String] {
        MarkdownTimeCalculator.sums(in: text, result: MarkdownSyntax.parse(text))
            .map { MarkdownTimeCalculator.format($0.seconds) }
    }

    func testTravelDayAddsAndSubtracts() {
        let text = """
            Drive to airport 50m
            Security and waiting 1h 30m
            Flight 2h 55m
            Time zone -1h
            Travel day =
            """
        XCTAssertEqual(results(text), ["4h 15m"])
        let sum = MarkdownTimeCalculator.sums(in: text, skipping: [], boundaries: [])
        XCTAssertEqual(sum.first?.location, (text as NSString).length - 1)
    }

    func testOperatorAppliesOnlyToTheNextValueAcrossBlankLines() {
        XCTAssertEqual(results("1m\n\n-5m +\n\n1m\n="), ["-3m"])
        XCTAssertEqual(results("Time zone -1h\nTaxi 20m\n="), ["-40m"])
        XCTAssertEqual(results("2h - \n30m =\n"), ["1h 30m"])
        XCTAssertEqual(results("2h - later 30m ="), ["2h 30m"])
    }

    func testOperatorsWithoutSpacesFollowATime() {
        XCTAssertEqual(results("5h\n\nMo: +7m-1h-42m+26m\nDi:\n\nTotal ="), ["3h 51m"])
        XCTAssertEqual(results("Mon-Fri 2h =\n1h-30m ="), ["2h", "30m"])
    }

    func testCompoundValuesShareTheirSign() {
        XCTAssertEqual(results("3h\n-1h 30m\n="), ["1h 30m"])
        XCTAssertEqual(results("3h\n-1h30m\n="), ["1h 30m"])
        XCTAssertEqual(results("-30m 1h ="), ["30m"])
    }

    func testValuesOnTheEqualsLineCount() {
        XCTAssertEqual(results("2h + 30m ="), ["2h 30m"])
        XCTAssertEqual(results("Half a day 0.5d, a break 1,5h ="), ["13h 30m"])
        XCTAssertEqual(results("5 m and 2 h ="), ["2h 5m"])
    }

    func testSumsEndAtEqualsLinesAndHeadings() {
        let text = """
            1h
            First =
            20m
            Second =

            10m
            # Next day
            5m
            Third =
            """
        XCTAssertEqual(results(text), ["1h", "20m", "5m"])
        XCTAssertEqual(results("# Total =\n1h"), [])
    }

    func testOnlyTimesAtWordBoundariesCount() {
        XCTAssertEqual(results("5min, 3 days, 2 hours, mp3m, v1.5h, 10s ="), ["10s"])
        XCTAssertEqual(results("Version 2 and 7 apples =\n"), ["0m"])
    }

    func testListMarkersCodeAndLinksAreNotRead() {
        let text = """
            - 30m
            - -10m
            + 5m
            Inline `2h` stays code
            [Watch 3h](https://example.com/5m)
            ```
            9h
            Not a sum =
            ```
            Total =
            """
        XCTAssertEqual(results(text), ["25m"])
    }

    func testHighlightsAndHeadingUnderlinesDoNotAskForASum() {
        XCTAssertEqual(results("1h ==done=="), [])
        XCTAssertEqual(results("1h\n==="), [])
        XCTAssertEqual(results("1h\n=  "), ["1h"])
        XCTAssertEqual(results("1h\r\n=\r\n2h\r\n="), ["1h", "2h"])
    }

    func testEditorShowsResultsOnlyInLivePreviewOfEnabledNotes() {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        #if os(macOS)
        textView.string = "Flight 2h 55m\nTotal ="
        #else
        textView.text = "Flight 2h 55m\nTotal ="
        #endif
        MarkdownPresentation.configure(textView, mode: .livePreview)
        XCTAssertEqual(textView.markdownTimeSums, [])

        textView.markdownTimeCalculator = true
        XCTAssertEqual(textView.markdownTimeSums,
                       [MarkdownTimeSum(location: 20, seconds: 10_500)])

        MarkdownPresentation.refresh(textView, mode: .source)
        XCTAssertEqual(textView.markdownTimeSums, [])
        MarkdownPresentation.refresh(textView, mode: .livePreview)
        XCTAssertEqual(textView.markdownTimeSums.count, 1)
        textView.markdownTimeCalculator = false
        XCTAssertEqual(textView.markdownTimeSums, [])
    }

    func testHugeNumbersDoNotCrash() {
        let digits = String(repeating: "9", count: 400)
        XCTAssertEqual(results("1234567890123456d =").count, 1)
        XCTAssertEqual(results("\(digits)h =").count, 1)
        XCTAssertEqual(results("-\(digits)h =").count, 1)
    }

    func testFormatUsesLargestUnitsFirstAndDropsZeros() {
        XCTAssertEqual(MarkdownTimeCalculator.format(0), "0m")
        XCTAssertEqual(MarkdownTimeCalculator.format(30), "30s")
        XCTAssertEqual(MarkdownTimeCalculator.format(-180), "-3m")
        XCTAssertEqual(MarkdownTimeCalculator.format(93_903), "1d 2h 5m 3s")
        XCTAssertEqual(MarkdownTimeCalculator.format(86_400 * 2 + 60), "2d 1m")
    }
}
