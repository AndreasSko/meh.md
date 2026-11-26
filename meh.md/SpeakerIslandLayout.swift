import CoreGraphics

/// Where Speaker Mode's floating island can go and where a drag lands it.
/// Points are the island's centre in the area it floats in, from the top
/// left; spots run from (0, 0) at top leading to (1, 1) at bottom trailing
/// of where it fits.
struct SpeakerIslandLayout {
    var areaSize: CGSize
    /// The island with the room its × takes.
    var islandSize: CGSize
    var margin: CGFloat
    /// Landing this close to a snap spot clicks it into place.
    var snapDistance: CGFloat
    /// The island's frame in the toolbar, or nil with no toolbar to dock in.
    var dock: CGRect?

    enum Landing: Equatable {
        case dock
        /// Clicked into one of the snap spots.
        case snap(CGPoint)
        /// Left where the drag was heading.
        case free(CGPoint)
    }

    static let snapSpots: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0),
        CGPoint(x: 0, y: 1), CGPoint(x: 0.5, y: 1), CGPoint(x: 1, y: 1),
    ]
    /// How quickly a flung island slows down, as for a scroll view: a
    /// fling travels about a tenth of its speed per second further.
    static let decelerationRate: CGFloat = 0.99
    /// Once over the toolbar, the island has to leave it by this much more,
    /// so it doesn't flicker in and out at the edge.
    static let dockHysteresis: CGFloat = 8

    /// Where the island's centre can go.
    var range: CGRect {
        let inset = CGSize(width: margin + islandSize.width / 2,
                           height: margin + islandSize.height / 2)
        return CGRect(x: inset.width, y: inset.height,
                      width: max(areaSize.width - inset.width * 2, 0),
                      height: max(areaSize.height - inset.height * 2, 0))
    }

    func point(for spot: CGPoint) -> CGPoint {
        CGPoint(x: range.minX + range.width * spot.x, y: range.minY + range.height * spot.y)
    }

    var dockPoint: CGPoint? {
        dock.map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    /// Whether the island's centre is over the toolbar, where letting go
    /// docks it.
    func isOverDock(_ point: CGPoint, wasOver: Bool) -> Bool {
        guard let dock else { return false }
        return point.y < dock.maxY + (wasOver ? Self.dockHysteresis : 0)
    }

    /// Where the island ends up when let go at `point`, moving at
    /// `velocity` points per second.
    func landing(from point: CGPoint, velocity: CGVector, wasOverDock: Bool) -> Landing {
        let end = Self.projected(point, velocity: velocity)
        if isOverDock(end, wasOver: wasOverDock) { return .dock }
        let range = range
        let clamped = CGPoint(x: min(max(end.x, range.minX), range.maxX),
                              y: min(max(end.y, range.minY), range.maxY))
        if let snap = Self.snapSpots.first(where: { spot in
            let snap = self.point(for: spot)
            return hypot(snap.x - clamped.x, snap.y - clamped.y) < snapDistance
        }) {
            return .snap(snap)
        }
        return .free(CGPoint(
            x: range.width > 0 ? (clamped.x - range.minX) / range.width : 0.5,
            y: range.height > 0 ? (clamped.y - range.minY) / range.height : 0
        ))
    }

    static func projected(_ point: CGPoint, velocity: CGVector) -> CGPoint {
        let distance = decelerationRate / (1 - decelerationRate) / 1000
        return CGPoint(x: point.x + velocity.dx * distance, y: point.y + velocity.dy * distance)
    }

    /// The finger's speed along the way from `start` to `end`, relative to
    /// that distance, as a spring's initial velocity takes it.
    static func springVelocity(from start: CGPoint, to end: CGPoint,
                               velocity: CGVector) -> Double {
        let way = CGVector(dx: end.x - start.x, dy: end.y - start.y)
        let length = way.dx * way.dx + way.dy * way.dy
        guard length > 1 else { return 0 }
        // A fling onto a nearby spot would otherwise overshoot wildly.
        return Double(min(max((velocity.dx * way.dx + velocity.dy * way.dy) / length, -20), 20))
    }
}
