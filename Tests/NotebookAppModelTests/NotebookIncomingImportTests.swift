import Foundation
import XCTest
@testable import NotebookAppModel

@MainActor
final class NotebookIncomingImportTests: XCTestCase {
    func testFileHandoffCopiesContentBeforeChoosingDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "Shared.md")
        let bytes = Data("# Shared note 👋\r\n".utf8)
        try bytes.write(to: file)
        let requests = NotebookIncomingImportRequests()
        requests.receive(file)
        await waitForReading(requests)
        let request = try XCTUnwrap(requests.requests.first)
        XCTAssertEqual(request.plan.entries.first?.name, "Shared.md")
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(Data(try XCTUnwrap(request.plan.entries.first?.text).utf8), bytes)
        requests.finish(request)
        XCTAssertTrue(requests.requests.isEmpty)
    }

    func testUnsupportedHandoffReportsErrorWithoutARequest() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not Markdown".utf8).write(to: file)
        let requests = NotebookIncomingImportRequests()
        requests.receive(file)
        await waitForReading(requests)
        XCTAssertTrue(requests.requests.isEmpty)
        XCTAssertNotNil(requests.errorMessage)
    }

    private func waitForReading(_ requests: NotebookIncomingImportRequests) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while requests.readingCount > 0 && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(requests.readingCount, 0)
    }
}
