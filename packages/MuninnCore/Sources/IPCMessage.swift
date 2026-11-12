import Foundation

// v2 IPC messages (design §4.6, §4.11). One JSON request per connection:
//   {"method": "<name>", "params": {...}}
// and one JSON response:
//   {"ok": true, "data": {...}}  or  {"ok": false, "error": {"code": "...", "message": "..."}}
// The transport is still v1's Unix socket until D21 / PROOF-002 decide.

public enum MuninnProtocol {
    /// Bumped on any incompatible message change; `hello` reports it.
    public static let version = 2
    /// `schemaVersion` carried by every CLI `--json` output.
    public static let cliSchemaVersion = 1
}

public enum IPCMethod: String, Codable, Sendable, CaseIterable {
    case hello, status, list, search, get, history, copy, pause, resume, pin, unpin, delete
}

public struct IPCRequest<Params: Codable & Sendable>: Codable, Sendable {
    public let method: String
    public let params: Params

    public init(_ method: IPCMethod, _ params: Params) {
        self.method = method.rawValue
        self.params = params
    }
}

/// Decodes just the method name, before the params type is known.
public struct IPCRequestHeader: Decodable, Sendable {
    public let method: String
}

public struct NoParams: Codable, Sendable, Equatable {
    public init() {}
}

public struct ItemIDParams: Codable, Sendable, Equatable {
    public let id: Int64
    public init(id: Int64) { self.id = id }
}

// MARK: - Errors

/// Stable error codes; the CLI maps each to an exit code (§4.11).
public enum IPCErrorCode: String, Codable, Sendable {
    case invalidRequest = "invalid_request"
    case notFound = "not_found"
    case unsupported
    case incompatible
    case busy
    case `internal`

    public var exitCode: Int32 {
        switch self {
        case .invalidRequest, .unsupported: 1
        case .notFound: 2
        case .internal: 7
        case .incompatible: 8
        case .busy: 9
        }
    }
}

public struct IPCFailure: Codable, Sendable, Equatable, Error {
    public let code: IPCErrorCode
    public let message: String

    public init(_ code: IPCErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

// MARK: - Response

public struct IPCResponse<T: Codable & Sendable>: Codable, Sendable {
    public let ok: Bool
    public let data: T?
    public let error: IPCFailure?

    public static func success(_ data: T) -> IPCResponse { IPCResponse(ok: true, data: data, error: nil) }
    public static func failure(_ error: IPCFailure) -> IPCResponse { IPCResponse(ok: false, data: nil, error: error) }

    public init(ok: Bool, data: T?, error: IPCFailure?) {
        self.ok = ok
        self.data = data
        self.error = error
    }

    /// The data, or the failure as a thrown error.
    public func get() throws -> T {
        if ok, let data { return data }
        throw error ?? IPCFailure(.internal, "malformed response")
    }
}

/// The shared encoder/decoder settings for IPC and CLI JSON.
public enum MuninnJSON {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601(date))
        }
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = parseISO8601(string) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(string)"))
        }
        return decoder
    }

    /// ISO-8601 UTC with milliseconds, e.g. `2026-11-12T09:30:00.123Z`.
    public static func iso8601(_ date: Date) -> String {
        // Round to the millisecond ourselves: the formatter truncates, so a
        // stored 123 ms (0.12299… as a Double) would print as .122.
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let (seconds, fraction) = ms.quotientAndRemainder(dividingBy: 1000)
        let whole = seconds - (fraction < 0 ? 1 : 0)
        let millis = (fraction + 1000) % 1000
        let base = Date(timeIntervalSince1970: TimeInterval(whole))
            .formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeZone(separator: .omitted))
        // base ends in "Z"; insert the milliseconds before it.
        return String(base.dropLast()) + String(format: ".%03lldZ", millis)
    }

    public static func parseISO8601(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(string, strategy: .iso8601)
    }
}

// MARK: - Response data

public struct HelloInfo: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public init(protocolVersion: Int) { self.protocolVersion = protocolVersion }
}

/// Capture counters shown by `status` (§4.8). Privacy skips are deliberately
/// absent: they leave no trace (invariant 4).
public struct CaptureCounters: Codable, Sendable, Equatable {
    public var observedChanges = 0
    public var missedChanges = 0
    public var droppedBackpressure = 0
    public var selfCopies = 0
    public var omittedBySize = 0
    /// Changes offering nothing Muninn keeps (e.g. only app-private types).
    public var skippedUnsupported = 0
    public var storeErrors = 0

    public init() {}
}

public struct StatusInfo: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let itemCount: Int
    public let isPaused: Bool
    public let uptimeSeconds: Int
    public let dataDirectory: String
    public let isDevBuild: Bool
    public let counters: CaptureCounters

    public init(
        protocolVersion: Int, itemCount: Int, isPaused: Bool, uptimeSeconds: Int,
        dataDirectory: String, isDevBuild: Bool, counters: CaptureCounters
    ) {
        self.protocolVersion = protocolVersion
        self.itemCount = itemCount
        self.isPaused = isPaused
        self.uptimeSeconds = uptimeSeconds
        self.dataDirectory = dataDirectory
        self.isDevBuild = isDevBuild
        self.counters = counters
    }
}

public struct PausedState: Codable, Sendable, Equatable {
    public let isPaused: Bool
    public init(isPaused: Bool) { self.isPaused = isPaused }
}

public struct HistoryInfo: Codable, Sendable, Equatable {
    public let id: Int64
    public let events: [CaptureEventInfo]
    public init(id: Int64, events: [CaptureEventInfo]) {
        self.id = id
        self.events = events
    }
}

public struct ItemRef: Codable, Sendable, Equatable {
    public let id: Int64
    public init(id: Int64) { self.id = id }
}
