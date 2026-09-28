import Foundation
import NoteCore
import XCTest

@testable import NotebookAppModel

/// Opt-in model timing with synthetic files and an in-memory transport.
/// Native editor rendering, CloudKit, push delivery, and radios are excluded.
@MainActor
final class NotebookWorkspacePipelineBenchmarkTests: XCTestCase {
    private struct Fixture {
        let sender: NotebookWorkspace
        let receiver: NotebookWorkspace
        let senderSession: NoteSession
        let receiverSession: NoteSession
        let bodyBytes: Int
    }

    private struct Sample: Encodable {
        let path: String
        let notes: Int
        let repetition: Int
        let bodyBytes: Int
        let editMs: Int
        let flushMs: Int
        let scheduledWaitMs: Int?
        let senderCompletedMs: Int
        let senderExchangeMs: Int
        let receiverRefreshMs: Int
        let receiverExchangeMs: Int
        let editorToModelVisibleMs: Int
    }

    private enum BenchmarkError: Error {
        case timedOut
    }

    func testSyntheticAutomaticSchedulingThreeEdits() async throws {
        try requireOptIn()
        let fixture = try await prepareFixture(noteCount: 12)
        let sceneID = UUID()
        fixture.sender.sceneActivityChanged(id: sceneID, isActive: true)
        // Scene activation requests a refresh. Settle it before sampling the
        // normal idle-delay path for individual edits.
        await fixture.sender.refresh(manual: true)
        try assertExchangeSucceeded(fixture.sender)

        for repetition in 1...3 {
            let expected = fixture.senderSession.text + "Z"
            let priorEvents = fixture.sender.syncEventLog.entries.count
            let editStart = DispatchTime.now().uptimeNanoseconds
            let editMs = try commitOneLetter(expected, in: fixture)
            let flushStart = DispatchTime.now().uptimeNanoseconds
            try await fixture.senderSession.flush()
            let callbackDate = Date()
            fixture.sender.contentDidSave(trigger: "synthetic note persisted")
            let flushMs = milliseconds(since: flushStart)

            try await waitUntil(timeout: .seconds(120)) {
                let events = fixture.sender.syncEventLog.entries.dropFirst(priorEvents)
                let ended = events.contains {
                    $0.event == "pass_end" || $0.event.hasPrefix("pass_error:")
                }
                return ended && !fixture.sender.isRefreshing
            }
            try assertExchangeSucceeded(fixture.sender)
            let pass = try freshPass(in: fixture.sender, after: priorEvents)
            let scheduledWaitMs = Int(max(0,
                pass.start.timestamp.timeIntervalSince(callbackDate) * 1_000))
            let senderCompletedMs = milliseconds(since: editStart)

            let received = try await receive(expected, in: fixture)
            try emit(Sample(
                path: "automatic", notes: 12, repetition: repetition,
                bodyBytes: fixture.bodyBytes, editMs: editMs, flushMs: flushMs,
                scheduledWaitMs: scheduledWaitMs,
                senderCompletedMs: senderCompletedMs,
                senderExchangeMs: pass.durationMs,
                receiverRefreshMs: received.refreshMs,
                receiverExchangeMs: received.exchangeMs,
                editorToModelVisibleMs: received.visibleAtMs +
                    Int((received.startedAt - editStart) / 1_000_000)
            ))
        }
    }

    func testSyntheticManualLargeNotebookMatrix() async throws {
        try requireOptIn()
        for (noteCount, repetitions) in try manualCases() {
            let fixture = try await prepareFixture(noteCount: noteCount)
            for repetition in 1...repetitions {
                let expected = fixture.senderSession.text + "Z"
                let editStart = DispatchTime.now().uptimeNanoseconds
                let editMs = try commitOneLetter(expected, in: fixture)
                let flushStart = DispatchTime.now().uptimeNanoseconds
                try await fixture.senderSession.flush()
                fixture.sender.contentDidSave(trigger: "synthetic note persisted")
                let flushMs = milliseconds(since: flushStart)

                let priorEvents = fixture.sender.syncEventLog.entries.count
                await fixture.sender.refresh(manual: true)
                let senderCompletedMs = milliseconds(since: editStart)
                try assertExchangeSucceeded(fixture.sender)
                let senderPass = try freshPass(in: fixture.sender, after: priorEvents)

                let received = try await receive(expected, in: fixture)
                try emit(Sample(
                    path: "manual", notes: noteCount, repetition: repetition,
                    bodyBytes: fixture.bodyBytes, editMs: editMs,
                    flushMs: flushMs, scheduledWaitMs: nil,
                    senderCompletedMs: senderCompletedMs,
                    senderExchangeMs: senderPass.durationMs,
                    receiverRefreshMs: received.refreshMs,
                    receiverExchangeMs: received.exchangeMs,
                    editorToModelVisibleMs: received.visibleAtMs +
                        Int((received.startedAt - editStart) / 1_000_000)
                ))
            }
        }
    }

    private func requireOptIn() throws {
        guard ProcessInfo.processInfo.environment["MEH_RUN_MODEL_SYNC_BENCHMARK"] == "1"
        else {
            throw XCTSkip("Set MEH_RUN_MODEL_SYNC_BENCHMARK=1 to measure the model pipeline")
        }
        guard !UserDefaults.standard.bool(forKey: "meh.md.resetLocalStorage") else {
            throw XCTSkip("A pending app storage reset must complete first")
        }
    }

    /// Override with e.g. MEH_MODEL_BENCHMARK_CASES=100:3,1000:3.
    private func manualCases() throws -> [(Int, Int)] {
        guard let raw = ProcessInfo.processInfo.environment["MEH_MODEL_BENCHMARK_CASES"]
        else { return [(100, 3), (1_000, 3)] }
        let cases = raw.split(separator: ",").compactMap { part -> (Int, Int)? in
            let fields = part.split(separator: ":")
            guard fields.count == 2,
                  let notes = Int(fields[0]), let repetitions = Int(fields[1]),
                  (1...1_000).contains(notes), (1...5).contains(repetitions)
            else { return nil }
            return (notes, repetitions)
        }
        guard !cases.isEmpty, cases.count == raw.split(separator: ",").count else {
            throw XCTSkip("MEH_MODEL_BENCHMARK_CASES must contain N:R pairs")
        }
        return cases
    }

    private func prepareFixture(noteCount: Int) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "meh-model-benchmark-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let transport = InMemorySyncTransport(
            scope: "synthetic-\(UUID().uuidString)", store: InMemorySyncStore()
        )
        let sender = makeWorkspace(at: root.appending(path: "sender"), transport: transport)
        await sender.start()
        try assertExchangeSucceeded(sender)
        let senderReplica = try XCTUnwrap(sender.replica)

        // Fixture import, initial upload, and initial download are excluded.
        let body = "Synthetic Markdown note.\n" + String(repeating: "x", count: 176)
        let entries = (0..<noteCount).map { index in
            NotebookImportEntry(
                id: UUID(), kind: .note, name: "bench-\(index).md",
                parentID: nil, text: body
            )
        }
        try await senderReplica.importMarkdown(NotebookImportPlan(
            id: UUID(), entries: entries, skippedPaths: []
        ))
        let editedID = try XCTUnwrap(entries.first?.id)
        let senderSession = try await senderReplica.openNote(editedID)
        // Only the edited note has 12 prior revisions. Every other body has
        // its initial history, so this isolates notebook-size scaling.
        for index in 0..<12 {
            try senderSession.replaceAll(with: body + String(repeating: "a", count: index + 1))
            try await senderSession.flush()
        }
        await sender.refresh(manual: true)
        try assertExchangeSucceeded(sender)

        let receiver = makeWorkspace(
            at: root.appending(path: "receiver"), transport: transport
        )
        await receiver.start()
        try assertExchangeSucceeded(receiver)
        let receiverReplica = try XCTUnwrap(receiver.replica)
        let receiverSession = try await receiverReplica.openNote(editedID)
        XCTAssertEqual(receiverSession.text, senderSession.text)
        // Opening the receiving session can change local recent-note state.
        // Let both peers complete two ordinary passes before timing edits.
        for _ in 0..<2 {
            await sender.refresh(manual: true)
            try assertExchangeSucceeded(sender)
            await receiver.refresh(manual: true)
            try assertExchangeSucceeded(receiver)
        }
        let expectedCopy = senderSession.text
        for workspace in [sender, receiver] {
            let copy = try XCTUnwrap(workspace.copiesURL).appending(path: "bench-0.md")
            XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), expectedCopy)
        }
        return Fixture(
            sender: sender, receiver: receiver,
            senderSession: senderSession, receiverSession: receiverSession,
            bodyBytes: body.utf8.count
        )
    }

    private func makeWorkspace(
        at root: URL, transport: InMemorySyncTransport
    ) -> NotebookWorkspace {
        NotebookWorkspace(
            directory: root.appending(path: "Notebook"),
            documentsDirectory: root.appending(path: "Documents"),
            transport: transport, automaticSync: true
        )
    }

    private func commitOneLetter(_ expected: String, in fixture: Fixture) throws -> Int {
        let revision = try XCTUnwrap(fixture.senderSession.editorRevision)
        let started = DispatchTime.now().uptimeNanoseconds
        try fixture.senderSession.commitEditorText(expected, basedOn: revision)
        fixture.sender.noteDidEdit()
        return milliseconds(since: started)
    }

    private func receive(
        _ expected: String, in fixture: Fixture
    ) async throws -> (startedAt: UInt64, refreshMs: Int, exchangeMs: Int,
                       visibleAtMs: Int) {
        let priorEvents = fixture.receiver.syncEventLog.entries.count
        let started = DispatchTime.now().uptimeNanoseconds
        let refresh = Task { await fixture.receiver.refresh(manual: true) }
        try await waitUntil(timeout: .seconds(120)) {
            fixture.receiverSession.text == expected
                || fixture.receiver.sync?.lastError != nil
        }
        let visibleAtMs = milliseconds(since: started)
        await refresh.value
        let refreshMs = milliseconds(since: started)
        try assertExchangeSucceeded(fixture.receiver)
        XCTAssertEqual(fixture.receiverSession.text, expected)
        let pass = try freshPass(in: fixture.receiver, after: priorEvents)
        try await fixture.receiverSession.flush()
        let copy = try XCTUnwrap(fixture.receiver.copiesURL).appending(path: "bench-0.md")
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), expected)
        return (started, refreshMs, pass.durationMs, visibleAtMs)
    }

    private func freshPass(
        in workspace: NotebookWorkspace, after eventCount: Int
    ) throws -> (start: NotebookSyncEventLog.Entry, durationMs: Int) {
        let events = workspace.syncEventLog.entries.dropFirst(eventCount)
        let start = try XCTUnwrap(events.first { $0.event == "pass_start" })
        let end = try XCTUnwrap(events.first { $0.event == "pass_end" })
        return (start, try XCTUnwrap(end.counts["durationMilliseconds"]))
    }

    private func assertExchangeSucceeded(_ workspace: NotebookWorkspace) throws {
        let coordinator = try XCTUnwrap(workspace.sync)
        XCTAssertNil(coordinator.lastError)
        if case .exchanged = coordinator.status {} else {
            XCTFail("Expected exchanged status, got \(coordinator.status)")
        }
        XCTAssertNil(workspace.copyError)
    }

    private func waitUntil(
        timeout: Duration, condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw BenchmarkError.timedOut }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func milliseconds(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    private func emit(_ sample: Sample) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var line = Data("MODEL_SYNC_BENCHMARK ".utf8)
        line.append(try encoder.encode(sample))
        line.append(contentsOf: "\n".utf8)
        FileHandle.standardOutput.write(line)
    }
}
