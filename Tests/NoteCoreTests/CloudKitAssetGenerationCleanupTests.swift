import Foundation
@testable import NoteCore
import XCTest

final class CloudKitAssetGenerationCleanupTests: XCTestCase {
    func testMissingRootStillCountsAsFirstUse() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudKitAbsentAssets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        CloudKitAssetGenerationCleanup.prunePreviousProcessGenerations(
            in: root
        )
        let current = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: current, withIntermediateDirectories: true
        )
        try Data("in flight".utf8).write(
            to: current.appendingPathComponent("snapshot")
        )
        CloudKitAssetGenerationCleanup.prunePreviousProcessGenerations(
            in: root
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
    }

    func testOnlyPriorProcessGenerationsArePruned() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudKitAssets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        let previous = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: previous, withIntermediateDirectories: true
        )
        try Data("old asset".utf8).write(
            to: previous.appendingPathComponent("snapshot")
        )
        let unrelated = root.appendingPathComponent("keep.txt")
        try Data("other".utf8).write(to: unrelated)

        CloudKitAssetGenerationCleanup.prunePreviousProcessGenerations(
            in: root
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))

        let current = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: current, withIntermediateDirectories: true
        )
        try Data("in flight".utf8).write(
            to: current.appendingPathComponent("snapshot")
        )
        CloudKitAssetGenerationCleanup.prunePreviousProcessGenerations(
            in: root
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
    }

    func testCompletedRetiredOperationDeletesAssetAfterLastLease() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudKitLease-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let document = try NoteDocument(noteID: UUID())
        try document.replaceAll(with: "pending")
        let record = SyncRecord(snapshot: document.snapshot())
        var staging = CloudKitAssetStaging(directory: directory)
        let directLease = try staging.retain(record)
        let engineLease = try staging.retain(record)

        staging.release(engineLease, uploadCompleted: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directLease.path))
        staging.release(directLease, uploadCompleted: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directLease.path))
    }
}
