import Foundation

public struct AssistantModel: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct AssistantMessage: Codable, Equatable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    public enum Status: String, Codable, Sendable {
        case complete
        case interrupted
        case failed
    }

    public let id: UUID
    public let role: Role
    public var text: String
    public var status: Status
    public let createdAt: Date
    public var toolActivities: [AssistantToolActivity]
    public var providerContext: String?

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        status: Status = .complete,
        createdAt: Date = Date(),
        toolActivities: [AssistantToolActivity] = [],
        providerContext: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.status = status
        self.createdAt = createdAt
        self.toolActivities = toolActivities
        self.providerContext = providerContext
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, status, createdAt, toolActivities, providerContext
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        role = try values.decode(Role.self, forKey: .role)
        text = try values.decode(String.self, forKey: .text)
        status = try values.decode(Status.self, forKey: .status)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        toolActivities = try values.decodeIfPresent([AssistantToolActivity].self, forKey: .toolActivities) ?? []
        providerContext = try values.decodeIfPresent(String.self, forKey: .providerContext)
    }
}

public enum AssistantEvent: Equatable, Sendable {
    case textDelta(String)
    case toolActivity(AssistantToolActivity)
    case providerContext(String)
    case completed
}

public protocol AssistantProvider: Sendable {
    var id: String { get }

    func models() async throws -> [AssistantModel]

    func stream(messages: [AssistantMessage], model: String, tools: AssistantToolContext?)
        -> AsyncThrowingStream<AssistantEvent, any Error>
}

public extension AssistantProvider {
    func stream(messages: [AssistantMessage], model: String)
        -> AsyncThrowingStream<AssistantEvent, any Error> {
        stream(messages: messages, model: model, tools: nil)
    }
}

public struct AssistantThread: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var messages: [AssistantMessage]
    public var updatedAt: Date
    public var notebookID: UUID?

    public init(
        id: UUID = UUID(),
        title: String = "New Chat",
        messages: [AssistantMessage] = [],
        updatedAt: Date = Date(),
        notebookID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.updatedAt = updatedAt
        self.notebookID = notebookID
    }
    private enum CodingKeys: String, CodingKey { case id, title, messages, updatedAt, notebookID }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        messages = try values.decode([AssistantMessage].self, forKey: .messages)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        notebookID = try values.decodeIfPresent(UUID.self, forKey: .notebookID)
    }
}
