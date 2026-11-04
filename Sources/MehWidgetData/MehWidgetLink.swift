import Foundation

/// What tapping a widget asks the app to do. The system hands widget links
/// to the app that owns the widget, so the scheme needs no registration.
public enum MehWidgetLink: Equatable, Sendable {
    case note(UUID)
    case newNote

    public static let scheme = "mehmd"

    public var url: URL {
        switch self {
        case .note(let id): URL(string: "\(Self.scheme)://note/\(id.uuidString)")!
        case .newNote: URL(string: "\(Self.scheme)://new")!
        }
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        switch (url.host()?.lowercased(), path.count) {
        case ("new", 0):
            self = .newNote
        case ("note", 1):
            guard let id = UUID(uuidString: path[0]) else { return nil }
            self = .note(id)
        default:
            return nil
        }
    }
}
