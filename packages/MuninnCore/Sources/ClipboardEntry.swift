import Foundation

public enum EntryKind: String, Codable, Sendable, Equatable {
    case text
    case image
    case file
    case files
    case richText = "rich_text"
    case html
    case unknown
}

public struct EntryMetadata: Codable, Sendable, Equatable {
    public let width: Int?
    public let height: Int?
    public let name: String?
    public let path: String?
    public let count: Int?
    public let names: [String]?

    public init(
        width: Int? = nil, height: Int? = nil,
        name: String? = nil, path: String? = nil,
        count: Int? = nil, names: [String]? = nil
    ) {
        self.width = width
        self.height = height
        self.name = name
        self.path = path
        self.count = count
        self.names = names
    }
}

public struct ClipboardEntry: Codable, Sendable, Equatable {
    public let id: Int64
    public let content: String
    public let contentHash: String
    public let createdAt: Date
    public let isPinned: Bool
    public let kind: EntryKind
    public let metadata: EntryMetadata?

    public init(
        id: Int64, content: String, contentHash: String,
        createdAt: Date, isPinned: Bool,
        kind: EntryKind = .text, metadata: EntryMetadata? = nil
    ) {
        self.id = id
        self.content = content
        self.contentHash = contentHash
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.kind = kind
        self.metadata = metadata
    }

    public var displayContent: String {
        switch kind {
        case .text:
            return content
        case .image:
            if let w = metadata?.width, let h = metadata?.height {
                return "<image \(w)\u{00D7}\(h)>"
            }
            return "<image>"
        case .file:
            if let name = metadata?.name {
                return "<file: \(name)>"
            }
            return "<file>"
        case .files:
            if let count = metadata?.count {
                return "<files: \(count) items>"
            }
            return "<files>"
        case .richText:
            return "<rich text>"
        case .html:
            return "<html>"
        case .unknown:
            return "<clipboard item>"
        }
    }
}
