import Foundation

public struct ClipboardEntry: Codable, Sendable, Equatable {
    public let id: Int64
    public let content: String
    public let contentHash: String
    public let createdAt: Date
    public let isPinned: Bool

    public init(id: Int64, content: String, contentHash: String, createdAt: Date, isPinned: Bool) {
        self.id = id
        self.content = content
        self.contentHash = contentHash
        self.createdAt = createdAt
        self.isPinned = isPinned
    }
}
