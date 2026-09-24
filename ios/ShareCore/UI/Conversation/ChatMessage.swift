import Foundation

public struct ChatMessage: Identifiable {
    public let id: UUID
    public let role: String // "system", "user", "assistant"
    public var content: String
    public var reasoning: String?
    public var images: [ImageAttachment]
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        role: String,
        content: String,
        reasoning: String? = nil,
        images: [ImageAttachment] = [],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.images = images
        self.timestamp = timestamp
    }
}
