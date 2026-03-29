import Foundation

// MARK: - Request

public struct IPCRequest: Codable, Sendable {
    public let method: String
    public let params: IPCParams

    public init(method: String, params: IPCParams) {
        self.method = method
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case method, params
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        method = try container.decode(String.self, forKey: .method)
        switch method {
        case "list":
            params = .list(try container.decode(IPCParams.ListParams.self, forKey: .params))
        case "get":
            params = .get(try container.decode(IPCParams.GetParams.self, forKey: .params))
        case "search":
            params = .search(try container.decode(IPCParams.SearchParams.self, forKey: .params))
        case "copy":
            params = .copy(try container.decode(IPCParams.CopyParams.self, forKey: .params))
        case "delete":
            params = .delete(try container.decode(IPCParams.DeleteParams.self, forKey: .params))
        case "pin":
            params = .pin(try container.decode(IPCParams.PinParams.self, forKey: .params))
        case "unpin":
            params = .unpin(try container.decode(IPCParams.UnpinParams.self, forKey: .params))
        case "status":
            params = .status
        case "pause":
            params = .pause
        case "resume":
            params = .resume
        default:
            params = .empty
        }
    }
}

public enum IPCParams: Codable, Sendable {
    case list(ListParams)
    case get(GetParams)
    case search(SearchParams)
    case copy(CopyParams)
    case delete(DeleteParams)
    case pin(PinParams)
    case unpin(UnpinParams)
    case status
    case pause
    case resume
    case empty

    public struct ListParams: Codable, Sendable {
        public let limit: Int?
        public let offset: Int?

        public init(limit: Int? = nil, offset: Int? = nil) {
            self.limit = limit
            self.offset = offset
        }
    }

    public struct GetParams: Codable, Sendable {
        public let id: Int64

        public init(id: Int64) {
            self.id = id
        }
    }

    public struct SearchParams: Codable, Sendable {
        public let query: String
        public let limit: Int?

        public init(query: String, limit: Int? = nil) {
            self.query = query
            self.limit = limit
        }
    }

    public struct CopyParams: Codable, Sendable {
        public let id: Int64

        public init(id: Int64) {
            self.id = id
        }
    }

    public struct DeleteParams: Codable, Sendable {
        public let id: Int64

        public init(id: Int64) {
            self.id = id
        }
    }

    public struct PinParams: Codable, Sendable {
        public let id: Int64

        public init(id: Int64) {
            self.id = id
        }
    }

    public struct UnpinParams: Codable, Sendable {
        public let id: Int64

        public init(id: Int64) {
            self.id = id
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .list(let params):
            try container.encode(params)
        case .get(let params):
            try container.encode(params)
        case .search(let params):
            try container.encode(params)
        case .copy(let params):
            try container.encode(params)
        case .delete(let params):
            try container.encode(params)
        case .pin(let params):
            try container.encode(params)
        case .unpin(let params):
            try container.encode(params)
        case .status, .pause, .resume, .empty:
            try container.encode([String: String]())
        }
    }

    public init(from decoder: Decoder) throws {
        // Standalone decoding fallback (prefer IPCRequest's method-aware decoding)
        let container = try decoder.singleValueContainer()
        if let getParams = try? container.decode(GetParams.self) {
            self = .get(getParams)
        } else if let listParams = try? container.decode(ListParams.self),
           (listParams.limit != nil || listParams.offset != nil) {
            self = .list(listParams)
        } else {
            self = .empty
        }
    }
}

// MARK: - Errors

public struct IPCErrorDetail: Codable, Sendable {
    public let category: String
    public let message: String

    public init(category: String, message: String) {
        self.category = category
        self.message = message
    }

    public static func invalidRequest(_ message: String) -> IPCErrorDetail {
        IPCErrorDetail(category: "invalid_request", message: message)
    }

    public static func notFound(_ message: String) -> IPCErrorDetail {
        IPCErrorDetail(category: "not_found", message: message)
    }

    public static func unsupported(_ message: String) -> IPCErrorDetail {
        IPCErrorDetail(category: "unsupported", message: message)
    }

    public static func internalFailure(_ message: String) -> IPCErrorDetail {
        IPCErrorDetail(category: "internal_failure", message: message)
    }
}

// MARK: - Response

public struct IPCResponse<T: Codable & Sendable>: Codable, Sendable {
    public let ok: Bool
    public let data: T?
    public let error: String?
    public let errorDetail: IPCErrorDetail?

    public static func success(_ data: T) -> IPCResponse {
        IPCResponse(ok: true, data: data, error: nil, errorDetail: nil)
    }

    public static func failure(_ error: String) -> IPCResponse<T> {
        IPCResponse(ok: false, data: nil, error: error, errorDetail: nil)
    }

    public static func failure(_ detail: IPCErrorDetail) -> IPCResponse<T> {
        IPCResponse(ok: false, data: nil, error: detail.message, errorDetail: detail)
    }

    public init(ok: Bool, data: T?, error: String?, errorDetail: IPCErrorDetail? = nil) {
        self.ok = ok
        self.data = data
        self.error = error
        self.errorDetail = errorDetail
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

public struct SearchResponseData: Codable, Sendable {
    public let entries: [ClipboardEntry]

    public init(entries: [ClipboardEntry]) {
        self.entries = entries
    }
}

public struct StatusResponseData: Codable, Sendable {
    public let running: Bool
    public let entryCount: Int
    public let dbPath: String
    public let uptimeSeconds: Int
    public let isPaused: Bool

    public init(running: Bool, entryCount: Int, dbPath: String, uptimeSeconds: Int, isPaused: Bool) {
        self.running = running
        self.entryCount = entryCount
        self.dbPath = dbPath
        self.uptimeSeconds = uptimeSeconds
        self.isPaused = isPaused
    }
}
