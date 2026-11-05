import CloudKit
import Foundation
import XCTest

@testable import NoteCore

/// Several devices edit one notebook through the real coordinator and
/// CloudKit transport while a seeded schedule injects faults and restarts.
/// Afterwards every device must hold the same notebook, with no lost edit
/// and no deleted note brought back.
///
/// Some notes are only ever edited by the device that created them. Their
/// edits replace random ranges with Unicode, CRLF and Markdown snippets, and
/// every device must end up with exactly the bytes a plain string model
/// predicts.
///
/// A failing seed can be replayed with `MEH_CLOUDKIT_CHAOS_SEEDS=<seed>`.
@MainActor
final class NotebookCloudKitChaosTests: XCTestCase {
    private static let defaultSeeds: [UInt64] = [0x5EED, 0xC0FFEE, 0xBAD5EED]
    private static let steps = 120
    private static let snippets = [
        "a", " ", "\n", "\r\n", "\t", "  \n", "# ", "**", "_", "`", "\\*",
        "- [ ] ", "1. ", "> ", "```\n", "[link](x)", "---\n",
        "e\u{301}", "\u{301}", "é", "🇩🇪", "👩\u{200D}👩\u{200D}👧",
        "👍🏽", "\u{200C}", "שלום", "مرحبا", "日本語", "\u{FEFF}",
    ]

    func testDevicesConvergeUnderRandomFaults() async throws {
        for seed in configuredSeeds() {
            try await runScenario(seed: seed)
        }
    }

    private func runScenario(seed: UInt64) async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "cloudkit-chaos-\(String(seed, radix: 16))-\(UUID())"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try FakeCloudKitServer(directory: root)
        var random = SeededGenerator(seed: seed)
        var log: [String] = []
        var devices: [Device] = []
        for index in 0..<3 {
            devices.append(
                try await Device.open(
                    root.appending(path: "device-\(index)"), server: server
                )
            )
        }
        for device in devices { await device.coordinator.synchronize() }

        var markers: [UUID: Set<String>] = [:]
        var exact: [UUID: (owner: Int, scalars: [Unicode.Scalar])] = [:]
        var deleted = Set<UUID>()
        var folders: [UUID] = []
        var crashes = 0
        var failedPasses = 0

        for step in 0..<Self.steps {
            let index = Int.random(in: 0..<devices.count, using: &random)
            let device = devices[index]
            let notes = device.liveNoteIDs
            let editable = notes.filter {
                exact[$0].map { $0.owner == index } ?? true
            }
            let marker = "d\(index)-s\(step)"
            switch Int.random(in: 0..<100, using: &random) {
            case 0..<22 where !editable.isEmpty:
                let id = editable.randomElement(using: &random)!
                let session = try await device.replica.openNote(id)
                if var scalars = exact[id]?.scalars {
                    let edit = randomEdit(of: scalars, using: &random)
                    log.append("\(marker) exact edit \(id) \(edit.log)")
                    try session.replaceText(
                        in: edit.utf16Range, with: edit.replacement
                    )
                    scalars.replaceSubrange(
                        edit.range, with: edit.replacement.unicodeScalars
                    )
                    exact[id]?.scalars = scalars
                } else {
                    log.append("\(marker) edit \(id)")
                    try session.replaceText(
                        in: NSRange(
                            location: session.text.utf16.count, length: 0
                        ),
                        with: marker + "\n"
                    )
                    markers[id, default: []].insert(marker)
                }
                try await session.flush()
            case 0..<34 where device.isJoined:
                log.append("\(marker) create")
                let parent = folders.filter {
                    device.replica.placements.map(\.item.id).contains($0)
                }.randomElement(using: &random)
                let text = marker + "\n"
                let id = try await device.replica.createNote(
                    name: "\(marker).md", text: text, parentID: parent
                )
                if Bool.random(using: &random) {
                    log[log.count - 1] += " exact"
                    exact[id] = (index, Array(text.unicodeScalars))
                } else {
                    markers[id] = [marker]
                }
            case 34..<38 where device.isJoined:
                log.append("\(marker) folder")
                folders.append(
                    try await device.replica.createFolder(name: marker)
                )
            case 38..<42 where !notes.isEmpty:
                let id = notes.randomElement(using: &random)!
                log.append("\(marker) delete \(id)")
                try await device.replica.setTrashed(id, true)
                try await device.replica.permanentlyDelete(
                    device.replica.deletionSelection(rootID: id)
                )
                deleted.insert(id)
            case 42..<72:
                log.append("\(marker) sync")
                await device.coordinator.synchronize()
            case 72..<80:
                let offline = Bool.random(using: &random)
                log.append("\(marker) offline=\(offline)")
                server.setOffline(offline)
            case 80..<92:
                let fault = randomFault(using: &random)
                log.append("\(marker) fault \(fault.name)")
                server.inject(fault.value)
            default:
                log.append("\(marker) restart")
                devices[index] = try await device.restarted(server: server)
            }
            // A simulated crash kills the process, so reopen from disk.
            if devices[index].coordinator.lastError is FakeCloudKitCrash {
                log.append("\(marker) crashed")
                crashes += 1
                devices[index] = try await devices[index].restarted(
                    server: server
                )
            } else if case .failed = devices[index].coordinator.status,
                      log.last?.hasSuffix("sync") == true {
                failedPasses += 1
            }
        }
        let summary = "Chaos seed \(String(seed, radix: 16)): "
            + "\(markers.count + exact.count) notes, "
            + "\(deleted.count) deleted, "
            + "\(crashes) crashes, \(failedPasses) failed passes\n"
        FileHandle.standardOutput.write(Data(summary.utf8))

        server.setOffline(false)
        server.clearFaults()
        for index in devices.indices {
            devices[index] = try await devices[index].restarted(server: server)
        }
        for _ in 0..<4 {
            for device in devices { await device.coordinator.synchronize() }
        }

        let context = "Seed \(String(seed, radix: 16)); steps:\n"
            + log.joined(separator: "\n")
        for device in devices {
            if case let .failed(message) = device.coordinator.status {
                XCTFail("\(device.name) failed: \(message)\n\(context)")
                return
            }
        }
        let expected = devices[0].replica.placements
        for device in devices {
            XCTAssertEqual(
                device.replica.placements, expected,
                "\(device.name) has a different notebook\n\(context)"
            )
            for (id, noteMarkers) in markers where !deleted.contains(id) {
                let text: String
                do {
                    text = try await device.replica.openNote(id).text
                } catch {
                    XCTFail("\(device.name) cannot open \(id): \(error)\n\(context)")
                    continue
                }
                for marker in noteMarkers where !text.contains(marker) {
                    XCTFail(
                        "\(device.name) lost \(marker) in \(id)\n\(context)"
                    )
                }
            }
            for (id, note) in exact where !deleted.contains(id) {
                let expectedText = String(String.UnicodeScalarView(note.scalars))
                guard let text = try? await device.replica.openNote(id).text
                else {
                    XCTFail("\(device.name) cannot open \(id)\n\(context)")
                    continue
                }
                XCTAssertEqual(
                    Array(text.utf8), Array(expectedText.utf8),
                    "\(device.name) changed the bytes of \(id)\n\(context)"
                )
            }
            for id in deleted {
                XCTAssertFalse(
                    device.replica.placements.contains { $0.item.id == id },
                    "\(device.name) resurrected \(id)\n\(context)"
                )
            }
        }
        for device in devices {
            let reopened = NotebookReplica(directory: device.notebookDirectory)
            try await reopened.load()
            XCTAssertEqual(
                reopened.placements, expected,
                "\(device.name) differs after reopening\n\(context)"
            )
        }
    }

    /// Replaces a random range of whole Unicode scalars, so an edit can land
    /// inside a grapheme cluster, as typing next to an accent does.
    private func randomEdit(
        of scalars: [Unicode.Scalar], using random: inout SeededGenerator
    ) -> (
        range: Range<Int>, utf16Range: NSRange, replacement: String,
        log: String
    ) {
        let start = Int.random(in: 0...scalars.count, using: &random)
        let length = Int.random(
            in: 0...min(4, scalars.count - start), using: &random
        )
        var replacement = ""
        if length == 0 || Bool.random(using: &random) {
            for _ in 0..<Int.random(in: 1...3, using: &random) {
                replacement += Self.snippets.randomElement(using: &random)!
            }
        }
        let utf16Offset = { (end: Int) in
            scalars[..<end].reduce(0) { $0 + $1.utf16.count }
        }
        let location = utf16Offset(start)
        let utf16Range = NSRange(
            location: location,
            length: utf16Offset(start + length) - location
        )
        let escaped = replacement.unicodeScalars.map {
            $0.isASCII && $0.value >= 0x20
                ? String($0) : String(format: "\\u{%X}", $0.value)
        }.joined()
        return (
            start..<(start + length), utf16Range, replacement,
            "\(utf16Range.location)+\(utf16Range.length) \"\(escaped)\""
        )
    }

    private func randomFault(
        using random: inout SeededGenerator
    ) -> (name: String, value: FakeCloudKitServer.Fault) {
        // Codes CKSyncEngine retries itself, and codes the app must handle.
        // Throttling codes are left out: they make the transport sleep.
        let codes: [CKError.Code] = [
            .networkFailure, .zoneBusy, .quotaExceeded, .serverRejectedRequest,
        ]
        switch Int.random(in: 0..<4, using: &random) {
        case 0:
            return ("crash after save", .crashAfterServerSave)
        case 1:
            return ("crash after fetch", .crashAfterFetchedChanges)
        default:
            let code = codes.randomElement(using: &random)!
            return ("save \(code.rawValue)", .failSave(code) { _ in true })
        }
    }

    private func configuredSeeds() -> [UInt64] {
        let value = ProcessInfo.processInfo.environment[
            "MEH_CLOUDKIT_CHAOS_SEEDS"
        ] ?? ""
        let seeds = value.split(separator: ",").compactMap {
            UInt64($0.trimmingCharacters(in: .whitespaces), radix: 16)
        }
        return seeds.isEmpty ? Self.defaultSeeds : Array(seeds.prefix(50))
    }
}

@MainActor
private struct Device {
    let name: String
    let directory: URL
    let replica: NotebookReplica
    let transport: CloudKitSyncTransport
    let coordinator: NotebookSyncCoordinator

    var notebookDirectory: URL { directory.appending(path: "notebook") }

    var isJoined: Bool { replica.catalogSnapshot != nil }

    var liveNoteIDs: [UUID] {
        replica.placements.filter {
            $0.item.kind == .note && !$0.isInTrash
                && !$0.item.isPermanentlyDeleted
        }.map(\.item.id)
    }

    static func open(
        _ directory: URL, server: FakeCloudKitServer
    ) async throws -> Device {
        let replica = NotebookReplica(
            directory: directory.appending(path: "notebook")
        )
        try await replica.load()
        let transport = try await CloudKitSyncTransport.makeNotebook(
            services: server.services,
            containerIdentifier: server.containerIdentifier,
            stateDirectory: directory.appending(path: "cloudkit")
        )
        return Device(
            name: directory.lastPathComponent,
            directory: directory,
            replica: replica,
            transport: transport,
            coordinator: NotebookSyncCoordinator(
                replica: replica, transport: transport
            )
        )
    }

    func restarted(server: FakeCloudKitServer) async throws -> Device {
        await transport.retire()
        // Opening checks the account online; the app retries until it can.
        let offline = server.offline
        server.setOffline(false)
        defer { server.setOffline(offline) }
        return try await Device.open(directory, server: server)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
