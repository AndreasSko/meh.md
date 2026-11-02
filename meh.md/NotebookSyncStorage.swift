import Foundation
import NoteCore
import Security

/// Where notebook sync keeps notes. iCloud is the default; S3 is an
/// advanced option in beta; off keeps notes on this device only.
enum NotebookSyncStorage: String, CaseIterable, Identifiable, Codable, Sendable {
    case iCloud, s3, off

    var id: Self { self }
    var usesS3: Bool { self == .s3 }

    /// Used in sentences such as "Synced with iCloud".
    var name: String {
        switch self {
        case .iCloud: "iCloud"
        case .s3: "S3"
        case .off: "this device"
        }
    }

    var title: String {
        switch self {
        case .iCloud: "iCloud"
        case .s3: "S3 Storage"
        case .off: "Off"
        }
    }
}

/// The saved storage choice. The S3 address lives in preferences, its access
/// key in the keychain of this device only.
struct NotebookSyncStorageStore {
    private static let storageKey = "meh.md.syncStorage"
    private static let s3Key = "meh.md.s3Configuration"
    private static let previousKey = "meh.md.previousSyncStorage"
    /// Each app build keeps its own key, so development builds never ask
    /// for the release build's item.
    private static var keychainService: String {
        (Bundle.main.bundleIdentifier ?? "de.andreas-sk.meh-md") + ".s3-sync"
    }

    var defaults: UserDefaults = .standard
    /// Tests keep credentials in memory instead of the keychain.
    var usesKeychain = true
    private let memory = CredentialBox()

    var storage: NotebookSyncStorage {
        defaults.string(forKey: Self.storageKey).flatMap(NotebookSyncStorage.init) ?? .iCloud
    }

    var s3Configuration: S3SyncConfiguration? {
        defaults.data(forKey: Self.s3Key).flatMap {
            try? JSONDecoder().decode(S3SyncConfiguration.self, from: $0)
        }
    }

    /// The storage used before the last switch, offered as the way back.
    var previousStorage: NotebookSyncStorage? {
        get { defaults.string(forKey: Self.previousKey).flatMap(NotebookSyncStorage.init) }
        nonmutating set { defaults.set(newValue?.rawValue, forKey: Self.previousKey) }
    }

    func save(storage: NotebookSyncStorage, s3: S3SyncConfiguration?) throws {
        defaults.set(storage.rawValue, forKey: Self.storageKey)
        if let s3 {
            defaults.set(try JSONEncoder().encode(s3), forKey: Self.s3Key)
        }
    }

    func credentials() throws -> S3Credentials? {
        guard usesKeychain else { return memory.value }
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecUseDataProtectionKeychain: true,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError(status: status)
        }
        return try JSONDecoder().decode(S3Credentials.self, from: data)
    }

    func saveCredentials(_ credentials: S3Credentials) throws {
        guard usesKeychain else {
            memory.value = credentials
            return
        }
        let data = try JSONEncoder().encode(credentials)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecUseDataProtectionKeychain: true,
        ]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var item = query
        item[kSecValueData] = data
        // Background sync runs while the device is locked.
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func removeCredentials() {
        guard usesKeychain else {
            memory.value = nil
            return
        }
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecUseDataProtectionKeychain: true,
        ] as CFDictionary)
    }

    struct KeychainError: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "The S3 access key could not be read from the keychain (\(status))."
        }
    }

    private final class CredentialBox: @unchecked Sendable {
        var value: S3Credentials?
    }
}
