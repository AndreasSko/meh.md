import CoreGraphics
import XCTest
@testable import NotebookAppModel

@MainActor
final class SpeakerIslandLayoutTests: XCTestCase {
    /// An iPhone-sized area with the island docked in the middle of the bar.
    /// It reaches 8 points below the area, into the home indicator's room.
    private let layout = SpeakerIslandLayout(
        areaSize: CGSize(width: 402, height: 778), islandSize: CGSize(width: 110, height: 44),
        insets: .init(top: 34, side: 8, bottom: -8), snapDistance: 40,
        dock: CGRect(x: 146, y: 0, width: 110, height: 44))

    func testTheIslandReachesCloseToTheSidesAndBottom() {
        let corner = layout.point(for: CGPoint(x: 0, y: 1))
        XCTAssertEqual(corner.x - 55, 8)
        XCTAssertEqual(778 - (corner.y + 22), -8)
        XCTAssertEqual(layout.point(for: CGPoint(x: 1, y: 0)).y - 22, 34)
    }

    func testSlowDropStaysWhereItWasLeft() {
        let landing = layout.landing(from: CGPoint(x: 150, y: 400), velocity: .zero,
                                     wasOverDock: false)
        guard case .free(let spot) = landing else {
            return XCTFail("Expected a free landing, got \(landing)")
        }
        XCTAssertEqual(layout.point(for: spot).x, 150, accuracy: 0.001)
        XCTAssertEqual(layout.point(for: spot).y, 400, accuracy: 0.001)
    }

    func testDropNearATopSpotClicksIntoIt() {
        let top = layout.point(for: CGPoint(x: 0.5, y: 0))
        let landing = layout.landing(from: CGPoint(x: top.x + 20, y: top.y + 20),
                                     velocity: .zero, wasOverDock: false)
        XCTAssertEqual(landing, .snap(CGPoint(x: 0.5, y: 0)))
    }

    func testNearTheBottomItStaysWhereItWasLeft() {
        let bottom = layout.point(for: CGPoint(x: 0.5, y: 1))
        let landing = layout.landing(from: CGPoint(x: bottom.x + 20, y: bottom.y - 10),
                                     velocity: .zero, wasOverDock: false)
        guard case .free(let spot) = landing else {
            return XCTFail("Expected a free landing, got \(landing)")
        }
        XCTAssertEqual(layout.point(for: spot).x, bottom.x + 20, accuracy: 0.001)
    }

    func testFlingCarriesTheIslandOnToWhereItWasHeading() {
        // Flung towards the bottom trailing corner from the middle, it stops
        // in the corner.
        let landing = layout.landing(from: CGPoint(x: 260, y: 520),
                                     velocity: CGVector(dx: 1500, dy: 2500), wasOverDock: false)
        XCTAssertEqual(landing, .free(CGPoint(x: 1, y: 1)))
    }

    func testFlingPastTheEdgeStopsInside() {
        let landing = layout.landing(from: CGPoint(x: 200, y: 400),
                                     velocity: CGVector(dx: -4000, dy: 0), wasOverDock: false)
        guard case .free(let spot) = landing else {
            return XCTFail("Expected a free landing, got \(landing)")
        }
        XCTAssertEqual(spot.x, 0)
    }

    func testDocksOnceTheIslandsCentreIsOverTheBar() {
        XCTAssertEqual(layout.landing(from: CGPoint(x: 200, y: 40), velocity: .zero,
                                      wasOverDock: false), .dock)
        XCTAssertNotEqual(layout.landing(from: CGPoint(x: 200, y: 50), velocity: .zero,
                                         wasOverDock: false), .dock)
    }

    func testFlingUpDocksAndFlingDownLeavesTheBar() {
        XCTAssertEqual(layout.landing(from: CGPoint(x: 200, y: 90),
                                      velocity: CGVector(dx: 0, dy: -800), wasOverDock: false),
                       .dock)
        XCTAssertNotEqual(layout.landing(from: CGPoint(x: 200, y: 30),
                                         velocity: CGVector(dx: 0, dy: 800), wasOverDock: true),
                          .dock)
    }

    func testOverTheBarHoldsOnAtTheEdge() {
        let edge = CGPoint(x: 200, y: 48)
        XCTAssertFalse(layout.isOverDock(edge, wasOver: false))
        XCTAssertTrue(layout.isOverDock(edge, wasOver: true))
        XCTAssertFalse(layout.isOverDock(CGPoint(x: 200, y: 60), wasOver: true))
    }

    func testWithoutAToolbarItNeverDocks() {
        var layout = layout
        layout.dock = nil
        XCTAssertFalse(layout.isOverDock(CGPoint(x: 200, y: 0), wasOver: true))
        XCTAssertEqual(layout.landing(from: CGPoint(x: 201, y: 0), velocity: .zero,
                                      wasOverDock: false),
                       .snap(CGPoint(x: 0.5, y: 0)))
    }

    func testSpringVelocityFollowsTheFingerAlongTheWay() {
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 0, y: 100)
        XCTAssertEqual(SpeakerIslandLayout.springVelocity(
            from: start, to: end, velocity: CGVector(dx: 0, dy: 300)), 3, accuracy: 0.001)
        XCTAssertEqual(SpeakerIslandLayout.springVelocity(
            from: start, to: end, velocity: CGVector(dx: 300, dy: 0)), 0, accuracy: 0.001)
        XCTAssertEqual(SpeakerIslandLayout.springVelocity(
            from: start, to: end, velocity: CGVector(dx: 0, dy: -9000)), -20, accuracy: 0.001)
        XCTAssertEqual(SpeakerIslandLayout.springVelocity(
            from: start, to: start, velocity: CGVector(dx: 0, dy: 300)), 0)
    }
}
