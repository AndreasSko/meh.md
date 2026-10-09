import Foundation
import CryptoKit

enum NotebookEditorPreferences {
    nonisolated static var store: UserDefaults {
        store(for: ProcessInfo.processInfo.environment)
    }

    nonisolated static func store(for environment: [String: String]) -> UserDefaults {
        guard let name = suiteName(for: environment) else { return .standard }
        guard let defaults = UserDefaults(suiteName: name) else {
            preconditionFailure("Could not open isolated editor preferences")
        }
        return defaults
    }

    nonisolated static func suiteName(for environment: [String: String]) -> String? {
        #if DEBUG && (!ICLOUD_ENABLED || ICLOUD_DEV) && !NOTEBOOK_PERFORMANCE_HOST
        func validID(_ value: String?) -> String? {
            guard let value,
                  value.range(of: "^[A-Za-z0-9_-]{1,64}$",
                              options: .regularExpression) != nil else { return nil }
            return value
        }

        let scope: String
        if environment["MEH_SYNC_TEST_TRANSPORT"] == "loopback" {
            guard environment["MEH_NOTEBOOK_PREVIEW"] != "1",
                  environment["MEH_SYNC_CLOUDKIT"] != "1",
                  let endpoint = environment["MEH_SYNC_URL"],
                  let url = URL(string: endpoint), url.scheme == "http",
                  ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""),
                  let workspace = validID(environment["MEH_SYNC_WORKSPACE"])
            else { return nil }
            scope = "loopback#\(url.absoluteString)#\(workspace)"
        } else {
            guard environment["MEH_NOTEBOOK_PREVIEW"] == "1",
                  environment["MEH_SYNC_TEST_TRANSPORT"] == nil,
                  environment["MEH_SYNC_URL"] == nil,
                  environment["MEH_SYNC_CLOUDKIT"] != "1",
                  let run = validID(environment["MEH_NOTEBOOK_PREVIEW_RUN"])
            else { return nil }
            scope = "preview#\(run)"
        }
        let digest = SHA256.hash(data: Data(scope.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        return "meh.md.editor-fixture.\(digest)"
        #else
        return nil
        #endif
    }
}
