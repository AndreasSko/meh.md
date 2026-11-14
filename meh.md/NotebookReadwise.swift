import Foundation
import NoteCore
import Observation
import Security
#if canImport(UIKit)
import UIKit
#endif

/// The Readwise Labs experiment on this device: setup, the syncing device,
/// when to sync, and the actions Settings and Note Actions offer. See
/// docs/readwise-sync.md.
@MainActor
@Observable
final class NotebookReadwise {
    static let enabledKey = "labs.readwise"
    private static let deviceKey = "readwise.deviceID"
    private static let keychainService = "de.andreas-sk.meh-md.readwise"
    /// While the app stays open, the syncing device checks this often.
    static let interval: Duration = .seconds(3 * 60 * 60)

    @ObservationIgnored private weak var workspace: NotebookWorkspace?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let usesKeychain: Bool
    @ObservationIgnored private var memoryTokens: [UUID: String] = [:]
    @ObservationIgnored private var syncsAfterNextICloudSync = false
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var templateTimer: Task<Void, Never>?
    @ObservationIgnored var makeSource: (String) -> any ReadwiseSource = { ReadwiseClient(token: $0) }

    private(set) var status: NotebookIntegrationStatus?
    private(set) var settings: [String: String] = [:]
    private(set) var isSyncing = false
    private(set) var lastError: String?
    private(set) var templateError: String?
    private(set) var deletedCount = 0
    private(set) var noteCount = 0
    /// The note Note Actions asked to reset, until the person confirms.
    var resetRequest: UUID?
    /// Books done and how many there are, while a sync runs.
    private(set) var progress: (done: Int, total: Int?)?

    init(workspace: NotebookWorkspace, defaults: UserDefaults = .standard, usesKeychain: Bool = true) {
        self.workspace = workspace
        self.defaults = defaults
        self.usesKeychain = usesKeychain
        #if DEBUG
        if ProcessInfo.processInfo.environment["MEH_READWISE_FIXTURE"] == "1" {
            let fixture = NotebookReadwiseFixture()
            makeSource = { _ in fixture }
        }
        #endif
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    var device: NotebookIntegrationDevice {
        let id = defaults.string(forKey: Self.deviceKey).flatMap(UUID.init) ?? {
            let id = UUID()
            defaults.set(id.uuidString, forKey: Self.deviceKey)
            return id
        }()
        return NotebookIntegrationDevice(id: id, kind: Self.deviceKind)
    }

    var isSyncingDevice: Bool { status?.syncingDevice?.id == device.id }

    // MARK: Status

    func reload() {
        guard let replica = workspace?.replica else { return }
        status = (try? NotebookIntegrationUpdates.connections(in: replica))?
            .first { $0.service == Readwise.service && $0.isConnected }
        settings = (try? updates()?.settings()) ?? [:]
        deletedCount = (try? updates()?.deletedItems().count) ?? 0
        noteCount = (try? updates()?.activeCount()) ?? 0
    }

    func record(forNote id: UUID) -> (record: NotebookIntegrationRecord, isDuplicate: Bool)? {
        try? updates()?.record(forNote: id)
    }

    var isTemplateNote: (UUID) -> Bool {
        let template = settings["template"].flatMap(UUID.init)
        return { $0 == template }
    }

    // MARK: Setup

    /// Checks the token and returns what the first sync imports, such as
    /// "2 Books and 1 Article".
    func checkToken(_ token: String) async throws -> String {
        let source = makeSource(token)
        try await source.checkToken()
        return Readwise.describe(try await source.bookCounts())
    }

    /// The token is saved first, so a Keychain failure leaves nothing
    /// behind; if connecting fails, the token goes again.
    func connect(token: String, folderName: String) async throws {
        let connection = UUID()
        try saveToken(token, connection: connection)
        do {
            _ = try await NotebookIntegrationUpdates.connect(
                replica: try replica(), service: Readwise.service, folderName: folderName,
                device: device, rendererVersion: ReadwiseRenderer.version, id: connection)
        } catch {
            removeToken(connection: connection)
            throw error
        }
        let updates = NotebookIntegrationUpdates(
            replica: try replica(), connection: connection, device: device,
            rendererVersion: ReadwiseRenderer.version)
        try await updates.setSetting("timeZone", TimeZone.current.identifier)
        reload()
        await sync()
    }

    func disconnect() async {
        await perform { updates in
            try await updates.disconnect()
            self.removeToken(connection: updates.connection)
        }
    }

    // MARK: Syncing

    /// Makes this device the syncing device and syncs now.
    func syncOnThisDevice() async {
        await perform { try await $0.claimSyncingDevice() }
        await sync()
    }

    /// `first` runs once the sync can start, before anything is fetched.
    func sync(
        bringingBack: Set<Int> = [],
        first: ((NotebookIntegrationUpdates) async throws -> Void)? = nil
    ) async {
        // A new instance has not read the connection yet, for example on
        // the timer or after launch without iCloud sync.
        if status == nil { reload() }
        guard isEnabled, !isSyncing, !isICloudPaused, let updates = try? updates(), isSyncingDevice,
              let token = token(connection: updates.connection) else { return }
        isSyncing = true
        defer {
            isSyncing = false
            progress = nil
            reload()
        }
        do {
            // Checked again once each batch has its turn, so a pause that
            // starts while a batch renders or waits still stops it.
            updates.beforeWrite = { [weak self] in
                if self?.isICloudPaused == true { throw ReadwisePausedError() }
            }
            let readwise = ReadwiseSync(
                updates: updates, source: makeSource(token),
                progressURL: progressURL(updates.connection))
            try readwise.bringBack(bringingBack)
            try await first?(updates)
            readwise.beforeBatch = { [weak self] in try await self?.waitForICloud() }
            // The template note may change in the exchange that runs now.
            try await waitForICloud()
            readwise.onProgress = { [weak self] done, total in self?.progress = (done, total) }
            let template = try await readwise.template()
            templateError = template.error
            guard !template.waiting else { return }
            _ = try await readwise.run(
                renderer: try renderer(template.source),
                includeSupplementals: settings["supplementals"] == "show",
                bringingBack: bringingBack)
            try await readwise.templateUsed(template)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The app became active. With iCloud sync, Readwise waits until that
    /// exchange has finished, so iCloud always goes first.
    func appDidBecomeActive() {
        startTimers()
        guard isEnabled else { return }
        if workspace?.usesSync == true {
            syncsAfterNextICloudSync = true
        } else {
            Task { await sync() }
        }
    }

    func appDidResignActive() {
        timer?.cancel()
        templateTimer?.cancel()
    }

    func iCloudDidSync() {
        reload()
        guard syncsAfterNextICloudSync else { return }
        syncsAfterNextICloudSync = false
        Task { await sync() }
    }

    private func startTimers() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                await self?.sync()
            }
        }
        // A template edit applies once it settles, without a button.
        templateTimer?.cancel()
        templateTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(90))
                guard let self, self.settings["template"] != nil, self.isSyncingDevice,
                      let updates = try? self.updates(),
                      let token = self.token(connection: updates.connection) else { continue }
                let readwise = ReadwiseSync(
                    updates: updates, source: self.makeSource(token),
                    progressURL: self.progressURL(updates.connection))
                guard let template = try? await readwise.template() else { continue }
                self.templateError = template.error
                guard !template.waiting, let renderer = try? self.renderer(template.source) else { continue }
                if readwise.needsFullRender(
                    renderer, includeSupplementals: self.settings["supplementals"] == "show")
                {
                    await self.sync()
                }
            }
        }
    }

    private func renderer(_ template: String) throws -> ReadwiseRenderer {
        try ReadwiseRenderer(template: template, options: ReadwiseRenderer.Options(
            blockIDs: settings["blockIDs"] != "off",
            timeZone: settings["timeZone"].flatMap(TimeZone.init(identifier:)) ?? .current))
    }

    /// iCloud sync paused for an app update or a halt. Readwise waits
    /// too, so it never writes while iCloud cannot exchange.
    private var isICloudPaused: Bool {
        workspace?.isSyncUpdateRequired == true || workspace?.syncHalt != nil
    }

    private func waitForICloud() async throws {
        while workspace?.isRefreshing == true {
            // Cancelled, the sleep would return at once and spin; the batch
            // that follows sees the cancellation and stops.
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
        if isICloudPaused { throw ReadwisePausedError() }
    }

    // MARK: Settings

    func setBlockIDs(_ enabled: Bool) async { await setRenderSetting("blockIDs", enabled ? nil : "off") }

    func setSupplementals(_ shown: Bool) async { await setRenderSetting("supplementals", shown ? "show" : nil) }

    /// The syncing device notices the change and renders every note again,
    /// also when the setting changed on another device.
    private func setRenderSetting(_ field: String, _ value: String?) async {
        await perform { try await $0.setSetting(field, value) }
        await sync()
    }

    /// Creates the template note in the Readwise folder, filled with the
    /// built-in layout, and selects it. Returns its ID to open it.
    func customizeTemplate() async -> UUID? {
        guard let updates = try? updates(), let folder = status?.folderID else { return nil }
        do {
            let id = try await updates.replica.createNote(
                name: "Readwise Template.md", text: ReadwiseRenderer.defaultTemplate, parentID: folder)
            try await updates.setSetting("template", id.uuidString)
            reload()
            return id
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func resetTemplate() async {
        guard let id = settings["template"].flatMap(UUID.init) else { return }
        await perform { updates in
            let session = try await updates.replica.openNote(id)
            try session.replaceAll(with: ReadwiseRenderer.defaultTemplate)
            try await session.flush()
        }
    }

    func useBuiltInTemplate() async {
        await perform { try await $0.setSetting("template", nil) }
        await sync()
    }

    func bringBackDeletedNotes() async {
        guard let keys = try? updates()?.deletedItems() else { return }
        await sync(bringingBack: Set(keys.compactMap(Int.init)))
    }

    /// Moves the note to Trash and imports its book again.
    /// The note goes to Trash only once the sync can start, and the
    /// request is saved before that, so it is never trashed for nothing.
    func reimport(noteID: UUID) async {
        guard let key = record(forNote: noteID)?.record.item, let id = Int(key) else { return }
        await sync(bringingBack: [id]) { try await $0.replica.setTrashed(noteID, true) }
    }

    // MARK: Helpers

    private func perform(_ body: (NotebookIntegrationUpdates) async throws -> Void) async {
        guard let updates = try? updates() else { return }
        do {
            try await body(updates)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        reload()
    }

    private func replica() throws -> NotebookReplica {
        guard let replica = workspace?.replica else { throw NotebookReplicaError.notJoined }
        return replica
    }

    private func updates() throws -> NotebookIntegrationUpdates? {
        guard let status else { return nil }
        return NotebookIntegrationUpdates(
            replica: try replica(), connection: status.connection, device: device,
            rendererVersion: ReadwiseRenderer.version)
    }

    private func progressURL(_ connection: UUID) -> URL {
        let base = workspace?.replica?.directory ?? FileManager.default.temporaryDirectory
        return base.appending(path: "integrations/\(connection.uuidString).json")
    }

    private static var deviceKind: String {
        #if os(macOS)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    // MARK: Token

    /// The connection exists but this device has no token for it, for
    /// example because the Keychain lost it.
    var needsToken: Bool {
        guard let status else { return false }
        return token(connection: status.connection) == nil
    }

    func replaceToken(_ token: String) async throws {
        guard let status else { return }
        try await makeSource(token).checkToken()
        try saveToken(token, connection: status.connection)
        lastError = nil
        reload()
    }

    /// One token per connection, in iCloud Keychain so any device can
    /// become the syncing device without a second setup.
    func token(connection: UUID) -> String? {
        guard usesKeychain else { return memoryTokens[connection] }
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword, kSecAttrService: Self.keychainService,
            kSecAttrAccount: connection.uuidString, kSecAttrSynchronizable: true,
            kSecUseDataProtectionKeychain: true, kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func saveToken(_ token: String, connection: UUID) throws {
        guard usesKeychain else {
            memoryTokens[connection] = token
            return
        }
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: Self.keychainService,
            kSecAttrAccount: connection.uuidString, kSecAttrSynchronizable: true,
            kSecUseDataProtectionKeychain: true,
        ]
        // Replaces a token in place, so a failure never leaves none.
        var status = SecItemUpdate(
            item as CFDictionary, [kSecValueData: Data(token.utf8)] as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(item.merging([
                kSecValueData: Data(token.utf8),
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            ]) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func removeToken(connection: UUID) {
        guard usesKeychain else {
            memoryTokens[connection] = nil
            return
        }
        SecItemDelete([
            kSecClass: kSecClassGenericPassword, kSecAttrService: Self.keychainService,
            kSecAttrAccount: connection.uuidString, kSecAttrSynchronizable: true,
            kSecUseDataProtectionKeychain: true,
        ] as CFDictionary)
    }
}

struct ReadwisePausedError: Error, LocalizedError {
    var errorDescription: String? { "Readwise waits until iCloud sync can continue." }
}

struct KeychainError: Error, LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        "The Readwise token could not be saved in the keychain (\(status))."
    }
}

#if DEBUG
/// Fictional Readwise books for UI tests and recordings, used with
/// `MEH_READWISE_FIXTURE=1`. After the first sync, one book gains a changed
/// and a new highlight.
final class NotebookReadwiseFixture: ReadwiseSource, @unchecked Sendable {
    private var syncs = 0

    func checkToken() async throws {}

    func export(
        updatedAfter: Date?, ids: [Int]?, includeDeleted: Bool, cursor: String?
    ) async throws -> Readwise.ExportPage {
        if updatedAfter != nil {
            syncs += 1
            return .init(results: [books(changed: true)[0]], nextPageCursor: nil)
        }
        let all = books(changed: syncs > 0)
        let results = ids.map { ids in all.filter { ids.contains($0.id) } } ?? all
        return .init(results: results, nextPageCursor: nil, count: all.count)
    }

    private func books(changed: Bool) -> [Readwise.Book] {
        [
            .init(id: 101, title: "The Quiet Garden", author: "Mira Holt",
                  highlights: [
                      .init(id: 1001, text: changed
                          ? "A garden grows in the pauses between the work, and in the work itself."
                          : "A garden grows in the pauses between the work.",
                          location: 12, locationType: "page"),
                      .init(id: 1002, text: "Water early, before the day decides for you.",
                            note: "Try this week.", location: 31, locationType: "page", tags: ["habit"]),
                  ] + (changed ? [.init(id: 1003, text: "Weeds are only plants out of place.",
                                        location: 58, locationType: "page")] : [])),
            .init(id: 102, title: "Notes on Walking", author: "Jonas Reed", category: "articles",
                  highlights: [.init(id: 2001, text: "Every walk is a small decision to look up.", location: 1)]),
            .init(id: 103, title: "Small Habits, Long Years", author: "Ada Linn",
                  highlights: [.init(id: 3001, text: "The calendar remembers what the mind forgets.",
                                     location: 40, locationType: "page")]),
        ]
    }
}
#endif
