import XCTest

@testable import NotebookAppModel

@MainActor
final class NotebookBrowserOrderingTests: XCTestCase {
    private let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let third = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    func testReorderPreservesSourceOrderAndParent() {
        let parent = UUID()
        let request = NotebookBrowserOrdering.request(
            sources: [third, first],
            before: second,
            parentID: parent,
            siblingIDs: [first, second, third]
        )

        XCTAssertEqual(
            request,
            NotebookBrowserReorderRequest(
                sources: [first, third], parentID: parent, before: second
            )
        )
    }

    func testNoOpAndForeignSourcesAreRejected() {
        XCTAssertNil(NotebookBrowserOrdering.request(
            sources: [first], before: second, parentID: nil,
            siblingIDs: [first, second, third]
        ))
        XCTAssertNil(NotebookBrowserOrdering.request(
            sources: [UUID()], before: second, parentID: nil,
            siblingIDs: [first, second, third]
        ))
    }

    func testMoveUpAndDownUseBeforeOrEnd() {
        XCTAssertEqual(
            NotebookBrowserOrdering.moveUpRequest(
                id: second, parentID: nil,
                siblingIDs: [first, second, third]
            )?.before,
            first
        )
        XCTAssertEqual(
            NotebookBrowserOrdering.moveDownRequest(
                id: second, parentID: nil,
                siblingIDs: [first, second, third]
            )?.before,
            nil
        )
        XCTAssertNil(NotebookBrowserOrdering.moveUpRequest(
            id: first, parentID: nil,
            siblingIDs: [first, second, third]
        ))
        XCTAssertNil(NotebookBrowserOrdering.moveDownRequest(
            id: third, parentID: nil,
            siblingIDs: [first, second, third]
        ))
    }

    func testProviderCopySurvivesExpiredSourceAndPreservesName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = root.appendingPathComponent("Provider")
        try FileManager.default.createDirectory(at: provider, withIntermediateDirectories: true)
        let source = provider.appendingPathComponent("Fictional report.bin")
        let bytes = Data([0, 255, 1, 2])
        try bytes.write(to: source)
        let staged = try NotebookBrowserFileStaging.copy(
            source, into: root.appendingPathComponent("Incoming")
        )
        try FileManager.default.removeItem(at: provider)
        XCTAssertEqual(staged.lastPathComponent, "Fictional report.bin")
        XCTAssertEqual(try Data(contentsOf: staged), bytes)
    }

    func testFailedProviderCopyLeavesNoPartialSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try NotebookBrowserFileStaging.copy(
            root.appendingPathComponent("Missing.pdf"), into: root
        ))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testProviderTemporaryNameUsesDisplayedNameAndKeepsExtension() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("provider-random-123.pdf")
        let bytes = Data([0, 255, 7, 3])
        try bytes.write(to: source)
        let staged = try NotebookBrowserFileStaging.copy(
            source, into: root.appendingPathComponent("Incoming"),
            preferredName: "Fictional report"
        )
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(staged.lastPathComponent, "Fictional report.pdf")
        XCTAssertEqual(try Data(contentsOf: staged), bytes)
        XCTAssertThrowsError(try NotebookBrowserFileStaging.copy(
            staged, into: root.appendingPathComponent("Incoming"),
            preferredName: "../escaped.pdf"
        ))
    }

}
