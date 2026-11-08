import Foundation
@testable import NoteCore
import XCTest

final class NotebookDirectoryLockTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "NotebookDirectoryLock-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRepeatedClaimsFromOneProcessSucceed() throws {
        let directory = root.appending(path: "Notebook")
        try NotebookDirectoryLock.claim(directory)
        try NotebookDirectoryLock.claim(directory)
        try NotebookDirectoryLock.claim(
            root.appending(path: "./Notebook/")
        )
    }

    func testSecondHolderIsRefusedUntilFirstCloses() throws {
        let url = NotebookDirectoryLock.lockFile(
            for: root.appending(path: "Notebook")
        )
        // Separate open() calls lock independently, like two processes.
        let first = try NotebookDirectoryLock.acquire(url)
        XCTAssertThrowsError(try NotebookDirectoryLock.acquire(url)) {
            XCTAssertEqual($0 as? NotebookDirectoryLock.InUse, .init())
        }
        close(first)
        close(try NotebookDirectoryLock.acquire(url))
    }

    func testLockFileSurvivesRemovingTheNotebook() throws {
        let directory = root.appending(path: "Notebook")
        let url = NotebookDirectoryLock.lockFile(for: directory)
        XCTAssertEqual(url.lastPathComponent, "Notebook.lock")
        XCTAssertEqual(
            url.deletingLastPathComponent().standardizedFileURL.path,
            root.standardizedFileURL.path
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let fd = try NotebookDirectoryLock.acquire(url)
        defer { close(fd) }
        try FileManager.default.removeItem(at: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    #if os(macOS)
    func testKilledHolderReleasesTheLock() throws {
        let directory = root.appending(path: "Notebook")
        let url = NotebookDirectoryLock.lockFile(for: directory)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = [
            "-e",
            """
            use Fcntl qw(:flock); open(my $f, '>>', $ARGV[0]) or die;
            flock($f, LOCK_EX) or die; $| = 1; print "locked\\n"; sleep 60;
            """,
            url.path
        ]
        let output = Pipe()
        holder.standardOutput = output
        try holder.run()
        defer { if holder.isRunning { holder.terminate() } }
        let line = output.fileHandleForReading.availableData
        XCTAssertEqual(String(bytes: line, encoding: .utf8), "locked\n")

        XCTAssertThrowsError(try NotebookDirectoryLock.acquire(url)) {
            XCTAssertEqual($0 as? NotebookDirectoryLock.InUse, .init())
        }
        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()
        close(try NotebookDirectoryLock.acquire(url))
    }
    #endif
}
