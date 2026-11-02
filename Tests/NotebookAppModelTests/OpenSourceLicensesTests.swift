import Foundation
import XCTest

@testable import NotebookAppModel

final class OpenSourceLicensesTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private struct Resolved: Decodable {
        struct Pin: Decodable {
            struct State: Decodable { let revision: String }
            let identity: String
            let state: State
        }
        let pins: [Pin]
    }

    private func licenses() throws -> OpenSourceLicenses {
        let data = try Data(contentsOf: root.appending(path: "meh.md/OpenSourceLicenses.json"))
        return try JSONDecoder().decode(OpenSourceLicenses.self, from: data)
    }

    func testListMatchesResolvedPackages() throws {
        let sources = try licenses().sources
        let rerun = "Run python3 scripts/generate_licenses.py."
        var pinned = Set<String>()
        for path in [
            "Package.resolved",
            "meh.md.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
        ] {
            let data = try Data(contentsOf: root.appending(path: path))
            for pin in try JSONDecoder().decode(Resolved.self, from: data).pins {
                XCTAssertEqual(sources[pin.identity], pin.state.revision,
                               "\(pin.identity) in \(path) changed. \(rerun)")
                pinned.insert(pin.identity)
            }
        }
        XCTAssertEqual(Set(sources.keys), pinned, "A package was removed. \(rerun)")
    }

    func testEveryPackageHasALicenseText() throws {
        let licenses = try licenses()
        XCTAssertFalse(licenses.packages.isEmpty)
        for package in licenses.packages {
            XCTAssertFalse(licenses.texts(for: package).isEmpty, package.id)
            XCTAssertEqual(licenses.texts(for: package).count, package.texts.count, package.id)
            XCTAssertEqual(Set(package.texts).count, package.texts.count, package.id)
        }
    }

    func testReflowJoinsWrappedLinesAndKeepsParagraphs() {
        XCTAssertEqual(
            OpenSourceLicenses.reflowed("MIT License\n\nPermission is\n  hereby granted.\n \nTHE SOFTWARE"),
            "MIT License\n\nPermission is hereby granted.\n\nTHE SOFTWARE"
        )
        XCTAssertEqual(
            OpenSourceLicenses.reflowed("Apache\r\n  Version 2.0\r\n\r\nTERMS"),
            "Apache Version 2.0\n\nTERMS"
        )
        XCTAssertEqual(
            OpenSourceLicenses.reflowed("1. The origin must\nnot be misrepresented.\n2. Altered versions\n   (a) must be marked"),
            "1. The origin must not be misrepresented.\n2. Altered versions\n(a) must be marked"
        )
    }
}
