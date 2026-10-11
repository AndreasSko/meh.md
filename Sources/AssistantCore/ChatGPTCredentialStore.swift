import Foundation
import Security

/// Saves one atomic record. Implementations must not log its contents.
public protocol ChatGPTCredentialStore: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

/// Credentials stay on this device and do not synchronize through iCloud.
public struct KeychainChatGPTCredentialStore: ChatGPTCredentialStore {
    private let service: String
    private let item = "current-account"

    public init(service: String = "md.meh.chatgpt.siwc") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: item,
         kSecAttrSynchronizable as String: false]
    }

    public func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ChatGPTAuthenticationError.storageFailure
        }
        return data
    }

    public func save(_ data: Data) throws {
        let changes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            insertion.merge(changes) { _, new in new }
            guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else {
                throw ChatGPTAuthenticationError.storageFailure
            }
        } else if status != errSecSuccess {
            throw ChatGPTAuthenticationError.storageFailure
        }
    }
}
