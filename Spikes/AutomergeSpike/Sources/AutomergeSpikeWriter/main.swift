import AutomergeSpike
import Darwin
import Foundation

private let noteID = UUID(
    uuidString: "9C86E52A-7037-4107-B7AA-148E3308A52D"
)!

private func printInspection(label: String, url: URL) {
    guard let data = try? Data(contentsOf: url),
          let note = try? SpikeNoteDocument(serializedData: data),
          let text = try? note.text else {
        print("\(label)=missing-or-invalid")
        return
    }
    print("\(label)=\(text)")
    print("\(label)-history=\(note.historyCount)")
    print(
        "\(label)-heads="
            + note.headsSnapshot.sorted().joined(separator: ",")
    )
}

private struct RecoveredNote {
    let document: SpikeNoteDocument
    let currentFailure: RecoveryFailure?
}

private func recoveredNote(from store: KnownGoodFileStore) throws
    -> RecoveredNote? {
    switch store.recover() {
    case .absent:
        return nil
    case .incompatibleCurrent:
        throw NSError(
            domain: "AutomergeSpikeWriter",
            code: 4,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "current file uses an unsupported schema version",
            ]
        )
    case let .current(data):
        return RecoveredNote(
            document: try SpikeNoteDocument(serializedData: data),
            currentFailure: nil
        )
    case let .previous(data, currentFailure):
        return RecoveredNote(
            document: try SpikeNoteDocument(serializedData: data),
            currentFailure: currentFailure
        )
    case let .unrecoverable(current, previous):
        throw NSError(
            domain: "AutomergeSpikeWriter",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "unrecoverable files: current=\(String(describing: current)) "
                    + "previous=\(String(describing: previous))",
            ]
        )
    }
}

private func quarantineFailedCurrent(
    for recovered: RecoveredNote,
    in store: KnownGoodFileStore
) throws {
    guard let failure = recovered.currentFailure else { return }
    let quarantineURL = try store.quarantineCurrent()
    print("recovered-from=previous")
    print("current-failure=\(failure)")
    print("quarantined-current=\(quarantineURL.path)")
}

private func pause(at stage: FileWriteStage, directory: URL) throws {
    let markerURL = directory.appendingPathComponent("stage.marker")
    try Data(stage.rawValue.utf8).write(to: markerURL, options: .atomic)
    while true {
        sleep(1)
    }
}

private func run() throws {
    let arguments = CommandLine.arguments
    guard arguments.count >= 3 else {
        throw NSError(
            domain: "AutomergeSpikeWriter",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "usage: write <directory> <text> [pause-stage] | "
                    + "append <directory> <text> [pause-stage] | "
                    + "branch <directory> <file> <text> | "
                    + "merge <directory> <file> | inspect <directory>",
            ]
        )
    }

    let command = arguments[1]
    let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
    let store = KnownGoodFileStore(directory: directory)

    switch command {
    case "write", "append":
        guard arguments.count >= 4 else {
            throw NSError(domain: "AutomergeSpikeWriter", code: 2)
        }
        let note: SpikeNoteDocument
        if let recovered = try recoveredNote(from: store) {
            note = recovered.document
            if command == "append" {
                let length = (try note.text as NSString).length
                try note.replaceUTF16(
                    range: NSRange(location: length, length: 0),
                    with: arguments[3]
                )
            } else {
                try note.replaceAll(with: arguments[3])
            }
            try quarantineFailedCurrent(for: recovered, in: store)
        } else {
            note = try SpikeNoteDocument(noteID: noteID, text: arguments[3])
        }
        let pauseStage = arguments.count >= 5
            ? FileWriteStage(rawValue: arguments[4])
            : nil
        try store.write(note.serializedData()) { stage in
            if stage == pauseStage {
                try pause(at: stage, directory: directory)
            }
        }
    case "branch":
        guard arguments.count >= 5,
              let recovered = try recoveredNote(from: store) else {
            throw NSError(domain: "AutomergeSpikeWriter", code: 2)
        }
        let branch = try recovered.document.fork()
        let length = (try branch.text as NSString).length
        try branch.replaceUTF16(
            range: NSRange(location: length, length: 0),
            with: arguments[4]
        )
        try branch.serializedData().write(
            to: URL(fileURLWithPath: arguments[3]),
            options: .atomic
        )
    case "merge":
        guard arguments.count >= 4,
              let recovered = try recoveredNote(from: store) else {
            throw NSError(domain: "AutomergeSpikeWriter", code: 2)
        }
        let branchData = try Data(
            contentsOf: URL(fileURLWithPath: arguments[3])
        )
        let branch = try SpikeNoteDocument(serializedData: branchData)
        try recovered.document.merge(branch)
        try quarantineFailedCurrent(for: recovered, in: store)
        try store.write(recovered.document.serializedData())
    case "inspect":
        printInspection(label: "current", url: store.currentURL)
        printInspection(label: "previous", url: store.previousURL)
    default:
        throw NSError(domain: "AutomergeSpikeWriter", code: 2)
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
