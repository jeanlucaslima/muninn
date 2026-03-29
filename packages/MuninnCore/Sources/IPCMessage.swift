import Foundation

// MARK: - Request

public struct IPCRequest: Codable, Sendable {
    public let method: String
    public let params: IPCParams

    public init(method: String, params: IPCParams) {
        self.method = method
        self.params = params
    }
}

public enum IPCParams: Codable, Sendable {
    case list(ListParams)
    case status
    case empty

    public struct ListParams: Codable, Sendable {
        public let limit: Int?
        public let offset: Int?

        public init(limit: Int? = nil, offset: Int? = nil) {
            self.limit = limit
            self.offset = offset
        }
    }

    // Custom coding: encode/decode as a flat JSON object
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let listParams = try? container.decode(ListParams.self),
           (listParams.limit != nil || listParams.offset != nil) {
            self = .list(listParams)
        } else {
            self = .empty
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .list(let params):
            try container.encode(params)
        case .status, .empty:
            try container.encode([String: String]())
        }
    }
}

// MARK: - Response

public struct IPCResponse<T: Codable & Sendable>: Codable, Sendable {
    public let ok: Bool
    public let data: T?
    public let error: String?

    public static func success(_ data: T) -> IPCResponse {
        IPCResponse(ok: true, data: data, error: nil)
    }

    public static func failure(_ error: String) -> IPCResponse<T> {
        IPCResponse(ok: true, data: nil, error: error)
    }

    public init(ok: Bool, data: T?, error: String?) {
        self.ok = ok
        self.data = data
        self.error = error
    }
}

// MARK: - Response Data Types

public struct ListResponseData: Codable, Sendable {
    public let entries: [ClipboardEntry]
    public let total: Int

    public init(entries: [ClipboardEntry], total: Int) {
        self.entries = entries
        self.total = total
    }
}

public struct StatusResponseData: Codable, Sendable {
    public let running: Bool
    public let entryCount: Int
    public let dbPath: String
    public let uptimeSeconds: Int

    public init(running: Bool, entryCount: Int, dbPath: String, uptimeSeconds: Int) {
        self.running = running
        self.entryCount = entryCount
        self.dbPath = dbPath
        self.uptimeSeconds = uptimeSeconds
    }
}
