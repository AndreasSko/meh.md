import Foundation

/// Asset files from a previous process cannot still be in use by that
/// process. Within this process, keep every generation because a canceled
/// CloudKit operation may still reference its CKAsset file.
enum CloudKitAssetGenerationCleanup {
    private static let lock = NSLock()
    // Access is always under lock, including the directory sweep.
    nonisolated(unsafe) private static var visitedRoots = Set<String>()

    static func prunePreviousProcessGenerations(in root: URL) {
        lock.lock()
        defer { lock.unlock() }
        let path = root.standardizedFileURL.path
        guard visitedRoots.insert(path).inserted else { return }
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else { return }
        for child in children {
            guard UUID(uuidString: child.lastPathComponent) != nil,
                  let values = try? child.resourceValues(forKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey
                  ]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }
            try? FileManager.default.removeItem(at: child)
        }
    }
}
