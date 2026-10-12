import Foundation

public struct AssistantToolDefinition: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let parameters: String
    public init(name: String, description: String, parameters: String) {
        self.name = name; self.description = description; self.parameters = parameters
    }
}

public struct AssistantToolCall: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let arguments: String
    public init(id: String, name: String, arguments: String) {
        self.id = id; self.name = name; self.arguments = arguments
    }
}

public struct AssistantNoteReference: Codable, Equatable, Identifiable, Sendable {
    public let notebookID: UUID
    public let noteID: UUID
    public let title: String
    public var id: UUID { noteID }
    public init(notebookID: UUID, noteID: UUID, title: String) {
        self.notebookID = notebookID; self.noteID = noteID; self.title = title
    }
}

public struct AssistantToolResult: Codable, Equatable, Sendable {
    public let callID: String
    public let output: String
    public let isError: Bool
    public let summary: String
    public let noteReferences: [AssistantNoteReference]
    public init(callID: String, output: String, isError: Bool = false,
                summary: String, noteReferences: [AssistantNoteReference] = []) {
        self.callID = callID; self.output = output; self.isError = isError
        self.summary = summary; self.noteReferences = noteReferences
    }
}

public struct AssistantToolActivity: Codable, Equatable, Identifiable, Sendable {
    public enum Phase: String, Codable, Sendable { case started, completed, failed }
    public let callID: String
    public let name: String
    public let phase: Phase
    public let summary: String
    public let noteReferences: [AssistantNoteReference]
    public let output: String?
    public var id: String { callID }
    public init(callID: String, name: String, phase: Phase, summary: String,
                noteReferences: [AssistantNoteReference] = [], output: String? = nil) {
        self.callID = callID; self.name = name; self.phase = phase
        self.summary = summary; self.noteReferences = noteReferences; self.output = output
    }
}

public protocol AssistantToolExecutor: Sendable {
    func execute(_ call: AssistantToolCall) async -> AssistantToolResult
}

public struct AssistantToolContext: Sendable {
    public let definitions: [AssistantToolDefinition]
    public let instructions: String
    public let executor: any AssistantToolExecutor
    /// Providers await this callback before execution and after its result.
    /// It records actions even when cancellation closes the event consumer.
    public let onActivity: @Sendable (AssistantToolActivity) async -> Void
    public init(definitions: [AssistantToolDefinition], instructions: String,
                executor: any AssistantToolExecutor,
                onActivity: @escaping @Sendable (AssistantToolActivity) async -> Void = { _ in }) {
        self.definitions = definitions; self.instructions = instructions; self.executor = executor
        self.onActivity = onActivity
    }
}
