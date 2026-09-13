#if DEBUG
import Foundation
import NoteCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct CloudKitSmokeLaunch {
    enum Phase: String {
        case single, publishMac = "publish-mac"
        case replyPhone = "reply-phone"
        case verifyMac = "verify-mac"
    }
    let phase: Phase
    let run: String
    let reportDirectory: URL
    let expectedRecordID: String?

    static var current: Self? {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["MEH_CLOUDKIT_SMOKE_PHASE"],
           let phase = Phase(rawValue: raw), phase != .single,
           let run = env["MEH_CLOUDKIT_SMOKE_RUN"],
           run.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression)
             != nil {
            #if os(macOS)
            let base = env["MEH_CLOUDKIT_SMOKE_DIR"].map(URL.init(fileURLWithPath:))
                ?? URL.applicationSupportDirectory.appending(path: "CloudKitSmoke")
            #else
            let base = URL.applicationSupportDirectory.appending(path: "CloudKitSmoke")
            #endif
            return Self(
                phase: phase, run: run,
                reportDirectory: base.appending(path: run).appending(path: raw),
                expectedRecordID: env["MEH_CLOUDKIT_SMOKE_EXPECTED_RECORD"]
            )
        }
        #if os(macOS)
        if let path = env["MEH_CLOUDKIT_SMOKE_DIR"] {
            return Self(
                phase: .single, run: UUID().uuidString,
                reportDirectory: URL(fileURLWithPath: path), expectedRecordID: nil
            )
        }
        #endif
        return nil
    }
}

struct CloudKitSmokeCheckView: View {
    let launch: CloudKitSmokeLaunch
    @State private var started = false

    var body: some View {
        ProgressView("Checking isolated iCloud sync…").padding(40).task {
            guard !started else { return }
            started = true
            await execute()
        }
    }

    @MainActor private func execute() async {
        var report = SmokeReport.running(launch)
        do {
            try write(report)
            let result = try await Smoke.run(launch) { stage in
                report.stage = stage
                try write(report)
            }
            report.apply(result)
        } catch {
            report.fail(error)
        }
        report.finishedAt = Date()
        do { try write(report) }
        catch {
            FileHandle.standardError.write(
                Data("CloudKit smoke report write failed: \(error)\n".utf8)
            )
            exit(EXIT_FAILURE)
        }
        if report.status == "passed" {
            #if os(macOS)
            NSApplication.shared.terminate(nil)
            #else
            exit(EXIT_SUCCESS)
            #endif
        } else { exit(EXIT_FAILURE) }
    }

    private func write(_ report: SmokeReport) throws {
        try FileManager.default.createDirectory(
            at: launch.reportDirectory, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        try data.write(
            to: launch.reportDirectory.appending(path: "cloudkit-smoke-report.json"),
            options: .atomic
        )
    }
}

private enum Smoke {
    static let zone = "meh-md-smoke-v1"
    static let container = "iCloud.de.andreas-sk.meh-md"

    struct Result {
        let marker: String
        let canonicalRecordID: String
        let sourceRecordID: String?
        let receivedRecordID: String?
        let uploadedRecordID: String?
        let noteID: UUID
        let fetchedCount: Int
    }

    @MainActor static func run(
        _ launch: CloudKitSmokeLaunch,
        stage: (String) throws -> Void
    ) async throws -> Result {
        switch launch.phase {
        case .single: try await single(launch, stage)
        case .publishMac: try await publishMac(launch, stage)
        case .replyPhone: try await replyPhone(launch, stage)
        case .verifyMac: try await verifyMac(launch, stage)
        }
    }

    @MainActor private static func publishMac(
        _ launch: CloudKitSmokeLaunch, _ stage: (String) throws -> Void
    ) async throws -> Result {
        let transport = try await transport(launch)
        try stage("writer-ready")
        let seed = try await canonical(transport)
        let marker = macMarker(launch.run)
        let upload = try await branch(seed, appending: marker)
        try await transport.publish(upload)
        try stage("published-mac")
        return Result(
            marker: marker, canonicalRecordID: seed.id,
            sourceRecordID: seed.id, receivedRecordID: nil,
            uploadedRecordID: upload.id, noteID: upload.snapshot.noteID,
            fetchedCount: 0
        )
    }

    @MainActor private static func replyPhone(
        _ launch: CloudKitSmokeLaunch, _ stage: (String) throws -> Void
    ) async throws -> Result {
        let transport = try await transport(launch)
        try stage("reader-ready")
        let seed = try await canonical(transport)
        let records = try await fetchAll(transport)
        let mac = try await find(
            macMarker(launch.run), expectedID: launch.expectedRecordID,
            in: records
        )
        try stage("received-mac")
        let marker = phoneMarker(launch.run)
        let reply = try await merge(seed, mac, appending: marker)
        try await transport.publish(reply)
        try stage("published-phone")
        return Result(
            marker: marker, canonicalRecordID: seed.id,
            sourceRecordID: mac.id, receivedRecordID: mac.id,
            uploadedRecordID: reply.id, noteID: reply.snapshot.noteID,
            fetchedCount: records.count
        )
    }

    @MainActor private static func verifyMac(
        _ launch: CloudKitSmokeLaunch, _ stage: (String) throws -> Void
    ) async throws -> Result {
        let transport = try await transport(launch)
        try stage("reader-ready")
        let seed = try await canonical(transport)
        let records = try await fetchAll(transport)
        let mac = try await find(macMarker(launch.run), in: records)
        let phone = try await find(
            phoneMarker(launch.run), expectedID: launch.expectedRecordID,
            in: records
        )
        let session = await session(.current(seed.snapshot))
        try session.mergeRemote(mac.snapshot)
        try session.mergeRemote(phone.snapshot)
        try await session.flush()
        guard session.text.contains(macMarker(launch.run)),
              session.text.contains(phoneMarker(launch.run)) else {
            throw SmokeError.textMismatch
        }
        try stage("verified-roundtrip")
        return Result(
            marker: phoneMarker(launch.run), canonicalRecordID: seed.id,
            sourceRecordID: phone.id, receivedRecordID: phone.id,
            uploadedRecordID: nil, noteID: phone.snapshot.noteID,
            fetchedCount: records.count
        )
    }

    @MainActor private static func single(
        _ launch: CloudKitSmokeLaunch, _ stage: (String) throws -> Void
    ) async throws -> Result {
        let writer = try await transport(launch)
        let seed = try await canonical(writer)
        let marker = "meh.md CloudKit smoke \(launch.run)"
        let upload = try await branch(seed, appending: marker)
        try await writer.publish(upload)
        try stage("published")
        let reader = try await transport(launch)
        _ = try await canonical(reader)
        let records = try await fetchAll(reader)
        guard let received = records.first(where: { $0.id == upload.id }),
              received.snapshot == upload.snapshot else {
            throw SmokeError.recordMissing
        }
        let decoded = await session(.current(received.snapshot))
        guard decoded.text == append(marker, to: (await session(
            .current(seed.snapshot)
        )).text) else {
            throw SmokeError.textMismatch
        }
        return Result(
            marker: marker, canonicalRecordID: seed.id,
            sourceRecordID: seed.id, receivedRecordID: received.id,
            uploadedRecordID: upload.id, noteID: upload.snapshot.noteID,
            fetchedCount: records.count
        )
    }

    private static func transport(
        _ launch: CloudKitSmokeLaunch
    ) async throws -> CloudKitSyncTransport {
        try await CloudKitSyncTransport.make(
            containerIdentifier: container,
            stateDirectory: launch.reportDirectory.appending(
                path: "state-\(UUID().uuidString)"
            ),
            zoneName: zone
        )
    }

    @MainActor private static func canonical(
        _ transport: CloudKitSyncTransport
    ) async throws -> SyncRecord {
        let proposal = await session(.firstLaunch)
        try await proposal.flush()
        guard let snapshot = proposal.persistedSnapshot else {
            throw SyncError.localSaveRequired
        }
        return try await transport.bootstrap(proposing: SyncRecord(snapshot: snapshot))
    }

    @MainActor private static func branch(
        _ base: SyncRecord, appending marker: String
    ) async throws -> SyncRecord {
        let note = await session(.current(base.snapshot))
        try note.replaceAll(with: append(marker, to: note.text))
        try await note.flush()
        guard let snapshot = note.persistedSnapshot else {
            throw SyncError.localSaveRequired
        }
        return SyncRecord(snapshot: snapshot)
    }

    @MainActor private static func merge(
        _ base: SyncRecord, _ remote: SyncRecord, appending marker: String
    ) async throws -> SyncRecord {
        let note = await session(.current(base.snapshot))
        try note.mergeRemote(remote.snapshot)
        try await note.flush()
        try note.replaceAll(with: append(marker, to: note.text))
        try await note.flush()
        guard let snapshot = note.persistedSnapshot else {
            throw SyncError.localSaveRequired
        }
        return SyncRecord(snapshot: snapshot)
    }

    @MainActor private static func session(
        _ result: NoteLoadResult
    ) async -> NoteSession {
        let note = NoteSession(storage: SmokeStorage(result))
        await note.load()
        return note
    }

    private static func fetchAll(
        _ transport: CloudKitSyncTransport
    ) async throws -> [SyncRecord] {
        var cursor: String?
        var records: [SyncRecord] = []
        for _ in 0..<1_000 {
            let page = try await transport.fetch(after: cursor)
            records += page.records
            cursor = page.cursor
            if !page.hasMore { return records }
        }
        throw SmokeError.tooManyPages
    }

    @MainActor private static func find(
        _ marker: String, expectedID: String? = nil,
        in records: [SyncRecord]
    ) async throws -> SyncRecord {
        let candidates = expectedID.map { id in
            records.filter { $0.id == id }
        } ?? records
        for record in candidates {
            if (await session(.current(record.snapshot))).text.contains(marker) {
                return record
            }
        }
        throw SmokeError.recordMissing
    }

    private static func append(_ marker: String, to text: String) -> String {
        text + (text.isEmpty ? "" : "\n\n") + marker
    }
    private static func macMarker(_ run: String) -> String {
        "meh.md cross-device \(run) mac"
    }
    private static func phoneMarker(_ run: String) -> String {
        "meh.md cross-device \(run) phone"
    }
}

private actor SmokeStorage: NoteStorage {
    private var result: NoteLoadResult
    init(_ result: NoteLoadResult) { self.result = result }
    func load() -> NoteLoadResult { result }
    func save(_ snapshot: NoteSnapshot) { result = .current(snapshot) }
    func recover(_ recovery: NoteRecovery) throws -> NoteSnapshot {
        throw SyncError.unavailable("Smoke storage has no recovery state.")
    }
}

private enum SmokeError: Error, LocalizedError {
    case recordMissing, textMismatch, tooManyPages
    var errorDescription: String? {
        switch self {
        case .recordMissing: "The expected immutable CloudKit snapshot was not fetched."
        case .textMismatch: "The fetched Automerge history contained unexpected text."
        case .tooManyPages: "CloudKit replay exceeded the 1,000-page limit."
        }
    }
}

private struct SmokeReport: Codable {
    var status, stage, phase, run: String
    var startedAt: Date
    var finishedAt: Date?
    var zoneName, marker: String
    var canonicalRecordID, sourceRecordID, receivedRecordID: String?
    var uploadedRecordID, noteID: String?
    var fetchedRecordCount: Int
    var error, errorDomain: String?
    var errorCode, cloudKitErrorCode: Int?

    static func running(_ launch: CloudKitSmokeLaunch) -> Self {
        Self(
            status: "running", stage: "starting", phase: launch.phase.rawValue,
            run: launch.run, startedAt: Date(), finishedAt: nil,
            zoneName: Smoke.zone, marker: "", canonicalRecordID: nil,
            sourceRecordID: nil, receivedRecordID: nil, uploadedRecordID: nil,
            noteID: nil, fetchedRecordCount: 0, error: nil, errorDomain: nil,
            errorCode: nil, cloudKitErrorCode: nil
        )
    }
    mutating func apply(_ result: Smoke.Result) {
        status = "passed"; stage = "verified"; marker = result.marker
        canonicalRecordID = result.canonicalRecordID
        sourceRecordID = result.sourceRecordID
        receivedRecordID = result.receivedRecordID
        uploadedRecordID = result.uploadedRecordID
        noteID = result.noteID.uuidString
        fetchedRecordCount = result.fetchedCount
    }
    mutating func fail(_ failure: Error) {
        let ns = failure as NSError
        status = "failed"; stage = "failed"; error = failure.localizedDescription
        errorDomain = ns.domain; errorCode = ns.code
        cloudKitErrorCode = Self.ckCode(ns)
    }
    private static func ckCode(_ error: NSError) -> Int? {
        if error.domain == "CKErrorDomain" { return error.code }
        guard let nested = error.userInfo[NSUnderlyingErrorKey] as? NSError else {
            return nil
        }
        return ckCode(nested)
    }
}
#endif
