import Foundation
import MuninnCore
import MuninnStore
import MuninnClipboard
import MuninnIPC

// MARK: - Setup

try MuninnPaths.ensureDirectoryExists()

let store = try ClipboardStore(path: MuninnPaths.databasePath)
let startTime = Date()

print("muninnd: starting...")
print("muninnd: database at \(MuninnPaths.databasePath)")
print("muninnd: socket at \(MuninnPaths.socketPath)")

// MARK: - Clipboard Watcher (created before server so the handler can capture it)

let watcher = ClipboardWatcher { content in
    do {
        switch try store.insert(content) {
        case .stored(let entry):
            let preview = entry.content.prefix(60)
            print("muninnd: captured entry #\(entry.id): \(preview)\(entry.content.count > 60 ? "..." : "")")
        case .deduplicated:
            break
        case .skippedTooLarge(let contentSize, let maxSize):
            print("muninnd: skipped clipboard entry — content size \(contentSize) bytes exceeds limit of \(maxSize) bytes")
        }
    } catch {
        print("muninnd: error storing clipboard entry: \(error)")
    }
}

// MARK: - IPC Server

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601

func encode<T: Codable & Sendable>(_ response: IPCResponse<T>) throws -> Data {
    try encoder.encode(response)
}

let server = IPCServer(socketPath: MuninnPaths.socketPath) { request in
    do {
        switch request.method {
        case "list":
            var limit = 20
            var offset = 0
            if case .list(let params) = request.params {
                limit = params.limit ?? 20
                offset = params.offset ?? 0
            }
            guard limit > 0 else {
                return try encode(IPCResponse<String>.failure(.invalidRequest("limit must be greater than 0")))
            }
            guard offset >= 0 else {
                return try encode(IPCResponse<String>.failure(.invalidRequest("offset must not be negative")))
            }
            let result = try store.list(limit: limit, offset: offset)
            let data = ListResponseData(entries: result.entries, total: result.total)
            return try encode(IPCResponse.success(data))

        case "search":
            guard case .search(let params) = request.params else {
                return try encode(IPCResponse<String>.failure(.invalidRequest("missing query parameter")))
            }
            let trimmed = params.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return try encode(IPCResponse<String>.failure(.invalidRequest("query must not be empty")))
            }
            let limit = params.limit ?? 20
            guard limit > 0 else {
                return try encode(IPCResponse<String>.failure(.invalidRequest("limit must be greater than 0")))
            }
            let entries = try store.search(query: trimmed, limit: limit)
            return try encode(IPCResponse.success(SearchResponseData(entries: entries)))

        case "get":
            guard case .get(let params) = request.params else {
                return try encode(IPCResponse<String>.failure(.invalidRequest("missing id parameter")))
            }
            if let entry = try store.get(id: params.id) {
                return try encode(IPCResponse.success(entry))
            } else {
                return try encode(IPCResponse<String>.failure(.notFound("entry not found: \(params.id)")))
            }

        case "copy":
            guard case .copy(let params) = request.params else {
                return try encode(IPCResponse<String>.failure(.invalidRequest("missing id parameter")))
            }
            guard let entry = try store.get(id: params.id) else {
                return try encode(IPCResponse<String>.failure(.notFound("entry not found: \(params.id)")))
            }
            DispatchQueue.main.sync {
                ClipboardWriter.write(entry.content)
            }
            return try encode(IPCResponse.success(entry))

        case "delete":
            guard case .delete(let params) = request.params else {
                return try encode(IPCResponse<String>.failure(.invalidRequest("missing id parameter")))
            }
            let deleted = try store.delete(id: params.id)
            if deleted {
                return try encode(IPCResponse.success(["id": params.id]))
            } else {
                return try encode(IPCResponse<String>.failure(.notFound("entry not found: \(params.id)")))
            }

        case "pin":
            guard case .pin(let params) = request.params else {
                return try encode(IPCResponse<String>.failure(.invalidRequest("missing id parameter")))
            }
            let pinned = try store.pin(id: params.id)
            if pinned, let entry = try store.get(id: params.id) {
                return try encode(IPCResponse.success(entry))
            } else {
                return try encode(IPCResponse<String>.failure(.notFound("entry not found: \(params.id)")))
            }

        case "unpin":
            guard case .unpin(let params) = request.params else {
                return try encode(IPCResponse<String>.failure(.invalidRequest("missing id parameter")))
            }
            let unpinned = try store.unpin(id: params.id)
            if unpinned, let entry = try store.get(id: params.id) {
                return try encode(IPCResponse.success(entry))
            } else {
                return try encode(IPCResponse<String>.failure(.notFound("entry not found: \(params.id)")))
            }

        case "pause":
            DispatchQueue.main.sync { watcher.pause() }
            print("muninnd: clipboard watching paused")
            return try encode(IPCResponse.success(["paused": true]))

        case "resume":
            DispatchQueue.main.sync { watcher.resume() }
            print("muninnd: clipboard watching resumed")
            return try encode(IPCResponse.success(["paused": false]))

        case "status":
            let count = try store.count()
            let uptime = Int(Date().timeIntervalSince(startTime))
            let data = StatusResponseData(
                running: true,
                entryCount: count,
                dbPath: MuninnPaths.databasePath,
                uptimeSeconds: uptime,
                isPaused: watcher.paused
            )
            return try encode(IPCResponse.success(data))

        default:
            return try encode(IPCResponse<String>.failure(.unsupported("unknown method: \(request.method)")))
        }
    } catch {
        return try encoder.encode(IPCResponse<String>.failure(.internalFailure("\(error)")))
    }
}

try server.start()
print("muninnd: IPC server listening")

// MARK: - Start Clipboard Watcher

watcher.start()
print("muninnd: clipboard watcher active (polling every 0.5s)")

// MARK: - Signal Handling

let signalCallback: @convention(c) (Int32) -> Void = { signal in
    print("\nmuninnd: shutting down (signal \(signal))...")
    // Server.stop() removes the socket file
    unlink(MuninnPaths.socketPath)
    exit(0)
}

signal(SIGINT, signalCallback)
signal(SIGTERM, signalCallback)

// MARK: - Run

print("muninnd: ready")
RunLoop.main.run()
