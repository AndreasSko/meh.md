import Foundation

/// What a widget tap or a link from Shortcuts asks the app to do. Each
/// build registers its own scheme, so links from the iCloud Dev build
/// never open the release app.
public enum MehWidgetLink: Equatable, Sendable {
    case note(UUID)
    case newNote

    public static let scheme = Bundle.main.object(
        forInfoDictionaryKey: "MehURLScheme"
    ) as? String ?? "mehmd"

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
