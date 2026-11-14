import Foundation

/// One item an integration delivers, such as a Readwise book.
public struct NotebookIntegrationItem: Equatable, Sendable {
    /// The subfolder an item belongs in, such as Books. The key is stable;
    /// the name is only used when the folder is created.
    public struct Folder: Equatable, Sendable {
        public let key: String
        public let name: String

        public init(key: String, name: String) {
            self.key = key
            self.name = name
        }
    }

    public let key: String
    /// The note's file name, see `noteName(for:)`.
    public let name: String
    public let folder: Folder?
    public let blocks: [NotebookIntegrationBlock]
    /// Removed in the service. The note stays and stops updating.
    public let isRemoved: Bool

    public init(
        key: String, name: String, folder: Folder?,
        blocks: [NotebookIntegrationBlock], isRemoved: Bool = false
    ) {
        self.key = key
        self.name = name
        self.folder = folder
        self.blocks = blocks
        self.isRemoved = isRemoved
    }

    /// A valid note name for a title: path separators and control
    /// characters become spaces, and long titles are shortened.
    public static func noteName(for title: String) -> String {
        var cleaned = String(String.UnicodeScalarView(title.unicodeScalars.map {
            $0 == "/" || $0 == ":" || $0.properties.generalCategory == .control ? " " : $0
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.utf8.count > 200 { cleaned.removeLast() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { cleaned = "Untitled" }
        return cleaned + ".md"
    }
}

/// The device that syncs an integration. Only the person changes it.
public struct NotebookIntegrationDevice: Codable, Equatable, Sendable {
    /// A per-install ID.
    public let id: UUID
    /// iPhone, iPad or Mac.
    public let kind: String

    public init(id: UUID, kind: String) {
        self.id = id
        self.kind = kind
    }
}

public struct NotebookIntegrationStatus: Equatable, Sendable {
    public let connection: UUID
    public let service: String
    public let isConnected: Bool
    public let folderID: UUID?
    public let syncingDevice: NotebookIntegrationDevice?
    public let lastSync: Date?
    public let rendererVersion: Int
    /// The syncing device when it needs an app update to keep syncing.
    public let deviceNeedingUpdate: NotebookIntegrationDevice?
}

public enum NotebookIntegrationError: Error, Equatable, LocalizedError {
    case notConnected
    case notSyncingDevice
    case updateRequired
    case invalidItem(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "This integration is not connected."
        case .notSyncingDevice: "Another device syncs this integration."
        case .updateRequired: "Update meh.md to keep syncing."
        case .invalidItem(let key): "An item could not be read (\(key))."
        }
    }
}

/// Brings an integration's items into the notebook as ordinary notes and
/// keeps them up to date, following docs/readwise-sync.md. It knows no
/// service; an adapter such as Readwise turns its data into items.
@MainActor
public final class NotebookIntegrationUpdates {
    public struct Report: Equatable, Sendable {
        public var created: [UUID] = []
        public var updated: [UUID] = []
        /// Items whose note has not downloaded yet. Keep them and try again.
        public var pending: [String] = []
        /// This version renders newer than the notes; refetch everything.
        public var rendererUpgraded = false
    }

    public let replica: NotebookReplica
    public let connection: UUID
    public let device: NotebookIntegrationDevice
    public let rendererVersion: Int
    /// Runs between saving notes and the catalog write, for tests.
    var afterNotes: (@MainActor () async throws -> Void)?

    public init(
        replica: NotebookReplica, connection: UUID,
        device: NotebookIntegrationDevice, rendererVersion: Int
    ) {
        self.replica = replica
        self.connection = connection
        self.device = device
        self.rendererVersion = rendererVersion
    }

    // MARK: Connections

    public static func connections(
        in replica: NotebookReplica
    ) throws -> [NotebookIntegrationStatus] {
        guard let catalog = replica.integrationCatalog() else { return [] }
        return try catalog.integrationConnectionIDs().sorted { $0.uuidString < $1.uuidString }
            .compactMap { try status(of: $0, in: catalog) }
    }

    /// Sets up a connection with its folder at the top level. The device
    /// that sets it up syncs it.
    public static func connect(
        replica: NotebookReplica, service: String, folderName: String,
        device: NotebookIntegrationDevice, rendererVersion: Int
    ) async throws -> UUID {
        try NotebookName.validate(folderName)
        let connection = UUID()
        try await replica.integrationCatalogWrite { next in
            let folder = try next.add(kind: .folder, name: folderName)
            for (field, value) in [
                ("service", service), ("state", "active"), ("folder", folder.uuidString),
                ("folderName", folderName), ("renderer", String(rendererVersion)),
                ("device", try Self.encode(device)),
            ] {
                try next.setIntegrationSetting(field, value, connection: connection)
            }
        }
        return connection
    }

    public func status() throws -> NotebookIntegrationStatus? {
        guard let catalog = replica.integrationCatalog() else { return nil }
        return try Self.status(of: connection, in: catalog)
    }

    /// Makes this device the one that syncs. Only the person decides this.
    public func claimSyncingDevice() async throws {
        try await replica.integrationCatalogWrite { next in
            try next.setIntegrationSetting("device", try Self.encode(device), connection: connection)
            try next.setIntegrationSetting("needsUpdate", nil, connection: connection)
        }
    }

    /// Stops the connection. Its notes stay as ordinary notes.
    public func disconnect() async throws {
        try await replica.integrationCatalogWrite { next in
            try next.setIntegrationSetting("state", "disconnected", connection: connection)
        }
    }

    /// The integration item a note belongs to, also for a losing duplicate.
    public func record(forNote id: UUID) throws -> (record: NotebookIntegrationRecord, isDuplicate: Bool)? {
        guard let catalog = replica.integrationCatalog() else { return nil }
        for values in try catalog.integrationRecords(connection).values {
            guard let record = Self.merged(values) else { continue }
            if record.note == id { return (record, false) }
            if record.duplicates.contains(id) { return (record, true) }
        }
        return nil
    }

    // MARK: Updates

    /// Applies one batch of items. Call it in batches of a few dozen, so
    /// iCloud uploads and the person's own edits can go in between. With
    /// `force`, notes are compared block by block even when an item looks
    /// unchanged, which repairs a block a late change from another device
    /// set back.
    public func apply(
        _ items: [NotebookIntegrationItem],
        bringingBack: Set<String> = [],
        message: String? = nil,
        force: Bool = false,
        at date: Date = Date()
    ) async throws -> Report {
        // Batches for one notebook run one at a time: two overlapping
        // batches could both see an item without a note and create two.
        try await IntegrationBatches.gate(for: replica).run {
            try await self.applyBatch(
                items, bringingBack: bringingBack, message: message, force: force, at: date)
        }
    }

    private func applyBatch(
        _ items: [NotebookIntegrationItem], bringingBack: Set<String>,
        message: String?, force: Bool, at date: Date
    ) async throws -> Report {
        guard let catalog = replica.integrationCatalog() else { throw NotebookReplicaError.notJoined }
        let settings = try catalog.integrationSettings(connection)
        try checkStillWriting(settings, allowNewerRenderer: true)
        let stored = settings["renderer"]?.compactMap(Int.init).max() ?? 0
        if stored > rendererVersion {
            try await replica.integrationCatalogWrite { next in
                try next.setIntegrationSetting(
                    "needsUpdate", try Self.encode(device), connection: connection)
            }
            throw NotebookIntegrationError.updateRequired
        }
        for item in items {
            for key in [item.key] + (item.folder.map { [$0.key] } ?? []) {
                guard !key.isEmpty, Self.isFolderKey(item.folder?.key ?? "x") else {
                    throw NotebookIntegrationError.invalidItem(key)
                }
            }
            do { try NotebookName.validate(item.name) } catch {
                throw NotebookIntegrationError.invalidItem(item.key)
            }
        }

        // The last of repeated items wins, so one batch never creates two
        // notes for one item.
        var seen = Set<String>()
        let items = items.reversed().filter { seen.insert($0.key).inserted }.reversed()
        var report = Report(rendererUpgraded: stored < rendererVersion)
        let records = try catalog.integrationRecords(connection)
        let placements = Dictionary(
            try catalog.placements().map { ($0.item.id, $0) }, uniquingKeysWith: { first, _ in first })
        let link = { (item: String) in NotebookIntegrationLink(connection: self.connection, item: item) }

        // Notes first: each update is one change, merged like an incoming
        // iCloud change. The catalog records them afterwards, so a crash in
        // between only repeats work the notes already show.
        var plans: [Plan] = []
        for item in items {
            let values = records[item.key] ?? []
            guard var record = Self.merged(values) else {
                if !item.isRemoved { plans.append(.create(item)) }
                continue
            }
            let observed = record.state
            let conflicted = values.count > 1
            guard [Self.activeState, NotebookIntegrationRecord.removed,
                   NotebookIntegrationRecord.deleted].contains(record.state) else { continue }
            let placement = placements[record.note]
            if placement == nil || placement!.item.isPermanentlyDeleted
                || record.state == NotebookIntegrationRecord.deleted
            {
                if bringingBack.contains(item.key), !item.isRemoved {
                    plans.append(.create(item))
                } else if record.state != NotebookIntegrationRecord.deleted || conflicted {
                    record.state = NotebookIntegrationRecord.deleted
                    plans.append(.record(record, observed: observed))
                }
                continue
            }
            if placement!.isInTrash {
                if conflicted { plans.append(.record(record, observed: observed)) }
                continue
            }
            if item.isRemoved {
                if record.state != NotebookIntegrationRecord.removed || conflicted {
                    record.state = NotebookIntegrationRecord.removed
                    plans.append(.record(record, observed: observed))
                }
                continue
            }
            let hash = Self.hash(item)
            if !force, record.hash == hash, record.state == Self.activeState, !conflicted { continue }
            guard let note = try await replica.integrationNote(record.note) else {
                report.pending.append(item.key)
                continue
            }
            if try note.applyIntegration(item.blocks, link: link(item.key), at: date, message: message) {
                // The batch suspends between writes, so the connection may
                // have been disconnected or taken over meanwhile. The check
                // runs with the write, so a disconnect cannot land between.
                try await replica.mergeNote(note.snapshot()) {
                    guard let current = self.replica.integrationCatalog() else { return }
                    try self.checkStillWriting(try current.integrationSettings(self.connection))
                }
                report.updated.append(record.note)
            }
            record.state = Self.activeState
            plans.append(.follow(item, record, hash, observed: observed))
        }

        try await afterNotes?()
        // Then one catalog write for everything else.
        try await replica.integrationCatalogWrite { next in
            try self.checkStillWriting(try next.integrationSettings(self.connection))
            let root = try self.folder(field: "folder", name: settings["folderName"]?.first
                ?? "Integration", parent: nil, in: next)
            var folders: [String: UUID] = [:]
            @MainActor func folderID(_ folder: NotebookIntegrationItem.Folder?) throws -> UUID {
                guard let folder else { return root }
                if let id = folders[folder.key] { return id }
                let id = try self.folder(
                    field: "folder-\(folder.key)", name: folder.name, parent: root, in: next)
                folders[folder.key] = id
                return id
            }
            // Placements are read here, inside the write: the person may
            // have renamed, moved or trashed a note while notes were saved.
            let current = Dictionary(
                try next.placements().map { ($0.item.id, $0) }, uniquingKeysWith: { first, _ in first })
            let records = try next.integrationRecords(self.connection)
            // Bodies are saved before the catalog lists them, and new notes
            // are added together so each folder's order is read once.
            var added: [(id: UUID, kind: NotebookItemKind, name: String, parentID: UUID?)] = []
            for plan in plans {
                switch plan {
                case .create(let item):
                    if let existing = records[item.key].flatMap(Self.merged),
                       existing.state != NotebookIntegrationRecord.deleted,
                       let placement = current[existing.note], !placement.item.isPermanentlyDeleted,
                       !placement.isInTrash || !bringingBack.contains(item.key)
                    {
                        // A note for the item arrived meanwhile. Its blocks
                        // are not in it yet, so the caller tries again.
                        report.pending.append(item.key)
                        continue
                    }
                    let parent = try folderID(item.folder)
                    let note = try NoteDocument(text: "", metadata: .now(date))
                    try note.applyIntegration(item.blocks, link: link(item.key), at: date, message: message)
                    try await self.replica.noteStorage(note.noteID).save(note.snapshot())
                    added.append((note.noteID, .note, item.name, parent))
                    try next.setIntegrationRecord(NotebookIntegrationRecord(
                        item: item.key, note: note.noteID, hash: Self.hash(item), name: item.name,
                        folder: parent, state: Self.activeState), connection: self.connection)
                    report.created.append(note.noteID)
                case .record(let planned, let observed):
                    guard var record = Self.rebased(planned, observed: observed, on: records) else {
                        report.pending.append(planned.item)
                        continue
                    }
                    record.state = planned.state
                    try next.setIntegrationRecord(record, connection: self.connection)
                case .follow(let item, let planned, let hash, let observed):
                    // Duplicates learned meanwhile are kept. If another
                    // note won meanwhile, this update went to the wrong one.
                    guard var record = Self.rebased(planned, observed: observed, on: records) else {
                        report.pending.append(item.key)
                        continue
                    }
                    record.state = planned.state
                    let target = try folderID(item.folder)
                    if let placement = current[record.note], !placement.isInTrash,
                       !placement.item.isPermanentlyDeleted
                    {
                        if item.name != record.name, placement.item.name == record.name {
                            try next.rename(record.note, to: item.name)
                        }
                        if target != record.folder, placement.item.parentID == record.folder {
                            try next.move(record.note, to: target)
                        }
                    }
                    record.hash = hash
                    record.name = item.name
                    record.folder = target
                    try next.setIntegrationRecord(record, connection: self.connection)
                }
            }
            try next.add(added)
            try next.setIntegrationSetting(
                "lastSync", ISO8601DateFormatter().string(from: date), connection: self.connection)
            if report.rendererUpgraded {
                try next.setIntegrationSetting(
                    "renderer", String(self.rendererVersion), connection: self.connection)
            }
        }
        return report
    }

    // MARK: - Helpers

    /// The connection is active, this device syncs it, and no newer
    /// renderer took over. Checked at the start of a batch and again before
    /// each write, since the batch suspends in between.
    private func checkStillWriting(
        _ settings: [String: [String]], allowNewerRenderer: Bool = false
    ) throws {
        guard settings["state"]?.first == "active" else { throw NotebookIntegrationError.notConnected }
        guard try Self.decodeDevice(settings["device"]?.first)?.id == device.id else {
            throw NotebookIntegrationError.notSyncingDevice
        }
        if !allowNewerRenderer, (settings["renderer"]?.compactMap(Int.init).max() ?? 0) > rendererVersion {
            throw NotebookIntegrationError.updateRequired
        }
    }

    private enum Plan {
        case create(NotebookIntegrationItem)
        /// `observed` is the record's state when the plan was made.
        case record(NotebookIntegrationRecord, observed: String)
        case follow(NotebookIntegrationItem, NotebookIntegrationRecord, String, observed: String)
    }

    private static let activeState = NotebookIntegrationRecord.active

    /// A record planned before the catalog write, on top of the catalog's
    /// current values for its item. Nil when another note won meanwhile or
    /// the record's state changed, for example to deleted or to a state a
    /// newer version wrote; the item is then tried again.
    private static func rebased(
        _ planned: NotebookIntegrationRecord, observed: String,
        on records: [String: [NotebookIntegrationRecord]]
    ) -> NotebookIntegrationRecord? {
        guard let current = records[planned.item].flatMap(merged) else { return planned }
        return current.note == planned.note && current.state == observed ? current : nil
    }

    /// The lowest note ID wins among concurrent records for one item; the
    /// others become its duplicates.
    nonisolated static func merged(_ values: [NotebookIntegrationRecord]) -> NotebookIntegrationRecord? {
        guard var winner = values.min(by: { $0.note.uuidString < $1.note.uuidString }) else {
            return nil
        }
        var duplicates = Set(values.flatMap(\.duplicates))
        duplicates.formUnion(values.map(\.note))
        duplicates.remove(winner.note)
        winner.duplicates = duplicates.sorted { $0.uuidString < $1.uuidString }
        return winner
    }

    /// The folder a setting names. If several devices created one, the
    /// lowest usable ID wins. A missing or trashed folder is created again.
    private func folder(
        field: String, name: String, parent: UUID?, in next: NotebookCatalogDocument
    ) throws -> UUID {
        let values = try next.integrationSettings(connection)[field] ?? []
        let usable = Set(try next.placements().filter {
            $0.item.kind == .folder && !$0.isInTrash && !$0.item.isPermanentlyDeleted
        }.map(\.item.id))
        if let winner = values.compactMap(UUID.init).filter(usable.contains)
            .min(by: { $0.uuidString < $1.uuidString })
        {
            if values != [winner.uuidString] {
                try next.setIntegrationSetting(field, winner.uuidString, connection: connection)
            }
            return winner
        }
        let id = try next.add(kind: .folder, name: name, parentID: parent)
        try next.setIntegrationSetting(field, id.uuidString, connection: connection)
        return id
    }

    static func hash(_ item: NotebookIntegrationItem) -> String {
        var parts = [item.name, item.folder?.key ?? ""]
        for block in item.blocks { parts += [block.key, block.text] }
        return NoteDocument.integrationHash(parts.joined(separator: "\u{0}"))
    }

    private static func isFolderKey(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy {
            $0.isASCII && CharacterSet.alphanumerics.contains($0) || $0 == "-"
        }
    }

    private static func status(
        of connection: UUID, in catalog: NotebookCatalogDocument
    ) throws -> NotebookIntegrationStatus? {
        let settings = try catalog.integrationSettings(connection)
        guard let service = settings["service"]?.first else { return nil }
        return NotebookIntegrationStatus(
            connection: connection, service: service,
            isConnected: settings["state"]?.first == "active",
            folderID: settings["folder"]?.first.flatMap(UUID.init),
            syncingDevice: try decodeDevice(settings["device"]?.first),
            lastSync: settings["lastSync"]?.first.flatMap { ISO8601DateFormatter().date(from: $0) },
            rendererVersion: settings["renderer"]?.compactMap(Int.init).max() ?? 0,
            deviceNeedingUpdate: try decodeDevice(settings["needsUpdate"]?.first))
    }

    private static func encode(_ device: NotebookIntegrationDevice) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(device), as: UTF8.self)
    }

    private static func decodeDevice(_ value: String?) throws -> NotebookIntegrationDevice? {
        value.flatMap { try? JSONDecoder().decode(NotebookIntegrationDevice.self, from: Data($0.utf8)) }
    }
}

/// Runs integration batches for one notebook one after another.
@MainActor
enum IntegrationBatches {
    private static var gates: [ObjectIdentifier: Gate] = [:]
    @TaskLocal static var held: Set<ObjectIdentifier> = []

    static func gate(for replica: NotebookReplica) -> Gate {
        let id = ObjectIdentifier(replica)
        if let gate = gates[id] { return gate }
        let gate = Gate(id: id)
        gates[id] = gate
        return gate
    }

    enum GateError: Error { case reentered }

    @MainActor
    final class Gate {
        let id: ObjectIdentifier
        private var busy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(id: ObjectIdentifier) { self.id = id }

        /// A batch that waited gets the gate handed over directly, so a
        /// later arrival cannot overtake it. A batch that starts another
        /// batch for the same notebook would wait for itself, so that fails.
        func run<T>(_ body: () async throws -> T) async throws -> T {
            guard !IntegrationBatches.held.contains(id) else { throw GateError.reentered }
            if busy {
                await withCheckedContinuation { waiters.append($0) }
            } else {
                busy = true
            }
            defer {
                if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
            }
            try Task.checkCancellation()
            return try await IntegrationBatches.$held.withValue(
                IntegrationBatches.held.union([id])) { try await body() }
        }
    }
}
