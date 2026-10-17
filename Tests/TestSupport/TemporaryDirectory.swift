import Foundation
import XCTest

extension XCTestCase {
    /// A unique path in the system temporary directory, removed when the test
    /// ends. The directory itself is not created.
    public func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "\(type(of: self))-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
