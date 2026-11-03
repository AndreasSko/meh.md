import Foundation

/// The app group folder the app and its widgets share. The app writes the
/// snapshot; a widget writes only which notes it needs content for.
public struct MehWidgetStore: Sendable {
    /// Info.plist key with the app group, which differs per build so the
    /// iCloud Dev app never shows the release app's notes.
    public static let appGroupKey = "MehAppGroup"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public init?(bundle: Bundle = .main) {
        guard let group = bundle.object(forInfoDictionaryKey: Self.appGroupKey) as? String,
              !group.isEmpty,
              let container = FileManager.default.containerURL(
                  forSecurityApplicationGroupIdentifier: group
              )
        else { return nil }
        directory = container.appendingPathComponent("Widgets", isDirectory: true)
    }

    private var snapshotURL: URL { directory.appendingPathComponent("snapshot.json") }
    private var requestsURL: URL { directory.appendingPathComponent("requests.json") }

    public func load() -> MehWidgetSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? Self.decoder.decode(MehWidgetSnapshot.self, from: data)
    }

    /// Returns whether the stored snapshot changed, so the caller reloads
    /// widgets only when they would show something new.
    @discardableResult
    public func save(_ snapshot: MehWidgetSnapshot) throws -> Bool {
        let data = try Self.encoder.encode(snapshot)
        if (try? Data(contentsOf: snapshotURL)) == data { return false }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try data.write(to: snapshotURL, options: .atomic)
        return true
    }

    /// The most requests kept. Older ones belong to widgets that most likely
    /// show another note by now, and a widget asks again when it needs to.
    public static let requestLimit = 8

    /// Notes picked in a One note widget whose content the snapshot lacks.
    /// The app adds their content the next time it writes the snapshot.
    public func requestedNoteIDs() -> Set<UUID> {
        Set(requests())
    }

    public func requestContent(for id: UUID) throws {
        var ids = requests()
        guard ids.last != id else { return }
        ids.removeAll { $0 == id }
        ids.append(id)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try write(Array(ids.suffix(Self.requestLimit)))
    }

    /// Forgets requests for notes that no longer exist.
    public func keepRequests(_ ids: Set<UUID>) throws {
        let current = requests()
        let kept = current.filter(ids.contains)
        guard kept != current else { return }
        try write(kept)
    }

    /// Oldest first.
    private func requests() -> [UUID] {
        guard let data = try? Data(contentsOf: requestsURL),
              let ids = try? Self.decoder.decode([UUID].self, from: data)
        else { return [] }
        return ids
    }

    private func write(_ ids: [UUID]) throws {
        try Self.encoder.encode(ids).write(to: requestsURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
