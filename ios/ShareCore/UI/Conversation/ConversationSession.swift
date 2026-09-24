import Foundation

public struct HistoryAnnotationContext: Hashable, Sendable {
    public let recordID: UUID
    public let targetIDs: Set<UUID>

    public init(
        recordID: UUID,
        targetIDs: Set<UUID>
    ) {
        self.recordID = recordID
        self.targetIDs = targetIDs
    }
}

public struct ConversationSession: Identifiable {
    public let id: UUID
    public let model: ModelConfig
    public let action: ActionConfig
    public let availableModels: [ModelConfig]
    public var messages: [ChatMessage]
    public var isStreaming: Bool
    public var streamingText: String
    /// Pre-filled user input to send immediately when the conversation opens.
    public var pendingInput: String?
    public var annotationContext: HistoryAnnotationContext?

    public init(
        id: UUID = UUID(),
        model: ModelConfig,
        action: ActionConfig,
        availableModels: [ModelConfig] = [],
        messages: [ChatMessage],
        isStreaming: Bool = false,
        streamingText: String = "",
        pendingInput: String? = nil,
        annotationContext: HistoryAnnotationContext? = nil
    ) {
        self.id = id
        self.model = model
        self.action = action
        self.availableModels = availableModels
        self.messages = messages
        self.isStreaming = isStreaming
        self.streamingText = streamingText
        self.pendingInput = pendingInput
        self.annotationContext = annotationContext
    }
}
