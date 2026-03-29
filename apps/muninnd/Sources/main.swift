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

// MARK: - IPC Server

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601

let server = IPCServer(socketPath: MuninnPaths.socketPath) { request in
    switch request.method {
    case "list":
        var limit = 20
        var offset = 0
        if case .list(let params) = request.params {
            limit = params.limit ?? 20
            offset = params.offset ?? 0
        }
        let result = try store.list(limit: limit, offset: offset)
        let data = ListResponseData(entries: result.entries, total: result.total)
        let response = IPCResponse.success(data)
        return try encoder.encode(response)

    case "status":
        let count = try store.count()
        let uptime = Int(Date().timeIntervalSince(startTime))
        let data = StatusResponseData(
            running: true,
            entryCount: count,
            dbPath: MuninnPaths.databasePath,
            uptimeSeconds: uptime
        )
        let response = IPCResponse.success(data)
        return try encoder.encode(response)

    default:
        let response = IPCResponse<String>(ok: false, data: nil, error: "unknown method: \(request.method)")
        return try encoder.encode(response)
    }
}

try server.start()
print("muninnd: IPC server listening")

// MARK: - Clipboard Watcher

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
