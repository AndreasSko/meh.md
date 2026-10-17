import XCTest

/// Polls until the condition holds. The generous default timeout only matters
/// when a test is about to fail, so slow CI machines don't cause flakes.
@MainActor
public func waitUntil(
    timeout: Duration = .seconds(10),
    _ message: @autoclosure () -> String = "Timed out waiting for condition",
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: @MainActor () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        guard clock.now < deadline else {
            XCTFail(message(), file: file, line: line)
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
