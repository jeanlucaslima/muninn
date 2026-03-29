import Foundation
import MuninnCore
import MuninnIPC

// MARK: - Argument Parsing

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"

func parseFlag(_ flag: String) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func hasFlag(_ flag: String) -> Bool {
    args.contains(flag)
}

// MARK: - Preview

/// Collapse whitespace into a single line and truncate to maxWidth.
func normalizePreview(_ content: String, maxWidth: Int) -> String {
    let collapsed = content
        .split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace || $0.isNewline })
        .joined(separator: " ")

    if collapsed.isEmpty {
        return "(empty)"
    }

    if collapsed.count <= maxWidth {
        return collapsed
    }

    return String(collapsed.prefix(maxWidth - 1)) + "\u{2026}"
}

// MARK: - Client

func makeClient() -> IPCClient {
    IPCClient(socketPath: MuninnPaths.socketPath)
}

func sendRequest(_ request: IPCRequest) -> Data {
    let client = makeClient()
    do {
        return try client.send(request)
    } catch {
        if "\(error)".contains("Connection refused") || "\(error)".contains("No such file") {
            fputs("muninnd is not running. Start it with: muninnd run\n", stderr)
        } else {
            fputs("error: \(error)\n", stderr)
        }
        exit(1)
    }
}

// MARK: - Response Helpers

func decodeResponse<T: Codable & Sendable>(_ data: Data, as type: T.Type) -> T? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let response = try? decoder.decode(IPCResponse<T>.self, from: data) else {
        fputs("error: failed to decode response\n", stderr)
        exit(1)
    }
    if !response.ok {
        fputs("error: \(response.error ?? "unknown error")\n", stderr)
        exit(1)
    }
    return response.data
}

func printEntries(_ entries: [ClipboardEntry]) {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short

    let maxPreviewWidth = 80
    let idWidth = entries.map { String($0.id).count }.max() ?? 1

    for entry in entries {
        let timestamp = formatter.string(from: entry.createdAt)
        let normalized = normalizePreview(entry.displayContent, maxWidth: maxPreviewWidth)
        let pinned = entry.isPinned ? " [pinned]" : ""
        let idStr = String(entry.id).padding(toLength: idWidth, withPad: " ", startingAt: 0)
        print("  #\(idStr)  \(timestamp)  \(normalized)\(pinned)")
    }
}

// MARK: - Commands

switch command {
case "list":
    let limit: Int
    if hasFlag("--all") {
        limit = Int.max
    } else {
        limit = parseFlag("--limit").flatMap(Int.init) ?? 20
    }
    let offset = parseFlag("--offset").flatMap(Int.init) ?? 0
    let jsonOutput = hasFlag("--json")

    let request = IPCRequest(
        method: "list",
        params: .list(.init(limit: limit, offset: offset))
    )
    let data = sendRequest(request)

    if jsonOutput {
        print(String(data: data, encoding: .utf8) ?? "{}")
    } else {
        guard let listData = decodeResponse(data, as: ListResponseData.self) else { exit(1) }

        if listData.entries.isEmpty {
            print("No clipboard entries yet.")
        } else {
            printEntries(listData.entries)
            print("\n\(listData.total) total entries")
        }
    }

case "search":
    guard let query = args.dropFirst().first else {
        fputs("usage: muninn search <query> [--limit N] [--json]\n", stderr)
        exit(1)
    }
    let limit = parseFlag("--limit").flatMap(Int.init) ?? 20
    let jsonOutput = hasFlag("--json")

    let request = IPCRequest(
        method: "search",
        params: .search(.init(query: String(query), limit: limit))
    )
    let data = sendRequest(request)

    if jsonOutput {
        print(String(data: data, encoding: .utf8) ?? "{}")
    } else {
        guard let searchData = decodeResponse(data, as: SearchResponseData.self) else { exit(1) }

        if searchData.entries.isEmpty {
            print("No entries matching \"\(query)\".")
        } else {
            printEntries(searchData.entries)
            print("\n\(searchData.entries.count) matching entries")
        }
    }

case "get":
    guard let idStr = args.dropFirst().first, let id = Int64(idStr) else {
        fputs("usage: muninn get <id> [--json]\n", stderr)
        exit(1)
    }
    let jsonOutput = hasFlag("--json")

    let request = IPCRequest(method: "get", params: .get(.init(id: id)))
    let data = sendRequest(request)

    if jsonOutput {
        print(String(data: data, encoding: .utf8) ?? "{}")
    } else {
        guard let entry = decodeResponse(data, as: ClipboardEntry.self) else { exit(1) }
        if entry.kind == .text {
            print(entry.content, terminator: "")
        } else {
            print(entry.displayContent)
        }
    }

case "copy":
    guard let idStr = args.dropFirst().first, let id = Int64(idStr) else {
        fputs("usage: muninn copy <id> [--json]\n", stderr)
        exit(1)
    }
    let jsonOutput = hasFlag("--json")

    let request = IPCRequest(method: "copy", params: .copy(.init(id: id)))
    let data = sendRequest(request)

    if jsonOutput {
        print(String(data: data, encoding: .utf8) ?? "{}")
    } else {
        guard let entry = decodeResponse(data, as: ClipboardEntry.self) else { exit(1) }
        print("copied #\(entry.id)")
    }

case "delete":
    guard let idStr = args.dropFirst().first, let id = Int64(idStr) else {
        fputs("usage: muninn delete <id> [--json]\n", stderr)
        exit(1)
    }
    let jsonOutput = hasFlag("--json")

    let request = IPCRequest(method: "delete", params: .delete(.init(id: id)))
    let data = sendRequest(request)

    if jsonOutput {
        print(String(data: data, encoding: .utf8) ?? "{}")
    } else {
        _ = decodeResponse(data, as: [String: Int64].self)
        print("deleted #\(id)")
    }

case "pin":
    guard let idStr = args.dropFirst().first, let id = Int64(idStr) else {
        fputs("usage: muninn pin <id> [--json]\n", stderr)
        exit(1)
    }
    let jsonOutput = hasFlag("--json")

    let request = IPCRequest(method: "pin", params: .pin(.init(id: id)))
    let data = sendRequest(request)

    if jsonOutput {
        print(String(data: data, encoding: .utf8) ?? "{}")
    } else {
        guard let entry = decodeResponse(data, as: ClipboardEntry.self) else { exit(1) }
        print("pinned #\(entry.id)")
    }

case "unpin":
    guard let idStr = args.dropFirst().first, let id = Int64(idStr) else {
        fputs("usage: muninn unpin <id> [--json]\n", stderr)
        exit(1)
    }
    let jsonOutput = hasFlag("--json")

    let request = IPCRequest(method: "unpin", params: .unpin(.init(id: id)))
    let data = sendRequest(request)

    if jsonOutput {
        print(String(data: data, encoding: .utf8) ?? "{}")
    } else {
        guard let entry = decodeResponse(data, as: ClipboardEntry.self) else { exit(1) }
        print("unpinned #\(entry.id)")
    }

case "pause":
    let jsonOutput = hasFlag("--json")

    let request = IPCRequest(method: "pause", params: .pause)
    let data = sendRequest(request)

    if jsonOutput {
        print(String(data: data, encoding: .utf8) ?? "{}")
    } else {
        _ = decodeResponse(data, as: [String: Bool].self)
        print("clipboard watching paused")
    }

case "resume":
    let jsonOutput = hasFlag("--json")

    let request = IPCRequest(method: "resume", params: .resume)
    let data = sendRequest(request)

    if jsonOutput {
        print(String(data: data, encoding: .utf8) ?? "{}")
    } else {
        _ = decodeResponse(data, as: [String: Bool].self)
        print("clipboard watching resumed")
    }

case "status":
    let request = IPCRequest(method: "status", params: .status)
    let data = sendRequest(request)

    if hasFlag("--json") {
        print(String(data: data, encoding: .utf8) ?? "{}")
    } else {
        guard let status = decodeResponse(data, as: StatusResponseData.self) else { exit(1) }

        let hours = status.uptimeSeconds / 3600
        let minutes = (status.uptimeSeconds % 3600) / 60
        let seconds = status.uptimeSeconds % 60

        print("muninnd status:")
        print("  running:  \(status.running)")
        print("  paused:   \(status.isPaused)")
        print("  entries:  \(status.entryCount)")
        print("  uptime:   \(hours)h \(minutes)m \(seconds)s")
        print("  database: \(status.dbPath)")
    }

case "help", "--help", "-h":
    print("""
    muninn — clipboard memory

    Usage:
      muninn list [--limit N] [--offset N] [--all] [--json]
      muninn search <query> [--limit N] [--json]
      muninn get <id> [--json]
      muninn copy <id> [--json]
      muninn delete <id> [--json]
      muninn pin <id> [--json]
      muninn unpin <id> [--json]
      muninn pause [--json]
      muninn resume [--json]
      muninn status [--json]
      muninn help

    Commands:
      list      List recent clipboard entries
      search    Search entries by content
      get       Show full content of an entry
      copy      Restore entry to clipboard
      delete    Remove entry from history
      pin       Pin an entry
      unpin     Unpin an entry
      pause     Pause clipboard watching
      resume    Resume clipboard watching
      status    Show daemon status
      help      Show this help
    """)

default:
    fputs("unknown command: \(command)\n", stderr)
    fputs("run 'muninn help' for usage\n", stderr)
    exit(1)
}
