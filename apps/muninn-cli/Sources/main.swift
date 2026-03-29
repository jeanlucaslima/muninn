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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let response = try? decoder.decode(IPCResponse<ListResponseData>.self, from: data),
              response.ok, let listData = response.data else {
            fputs("error: failed to decode response\n", stderr)
            exit(1)
        }

        if listData.entries.isEmpty {
            print("No clipboard entries yet.")
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short

            let maxPreviewWidth = 80
            let idWidth = listData.entries.map { String($0.id).count }.max() ?? 1

            for entry in listData.entries {
                let timestamp = formatter.string(from: entry.createdAt)
                let normalized = normalizePreview(entry.content, maxWidth: maxPreviewWidth)
                let pinned = entry.isPinned ? " [pinned]" : ""
                let idStr = String(entry.id).padding(toLength: idWidth, withPad: " ", startingAt: 0)
                print("  #\(idStr)  \(timestamp)  \(normalized)\(pinned)")
            }
            print("\n\(listData.total) total entries")
        }
    }

case "status":
    let request = IPCRequest(method: "status", params: .status)
    let data = sendRequest(request)

    if hasFlag("--json") {
        print(String(data: data, encoding: .utf8) ?? "{}")
    } else {
        let decoder = JSONDecoder()
        guard let response = try? decoder.decode(IPCResponse<StatusResponseData>.self, from: data),
              response.ok, let status = response.data else {
            fputs("error: failed to decode response\n", stderr)
            exit(1)
        }

        let hours = status.uptimeSeconds / 3600
        let minutes = (status.uptimeSeconds % 3600) / 60
        let seconds = status.uptimeSeconds % 60

        print("muninnd status:")
        print("  running:  \(status.running)")
        print("  entries:  \(status.entryCount)")
        print("  uptime:   \(hours)h \(minutes)m \(seconds)s")
        print("  database: \(status.dbPath)")
    }

case "copy":
    guard let idStr = args.dropFirst().first, let id = Int64(idStr) else {
        fputs("usage: muninn copy <id>\n", stderr)
        exit(1)
    }

    let request = IPCRequest(method: "get", params: .get(.init(id: id)))
    let data = sendRequest(request)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let response = try? decoder.decode(IPCResponse<ClipboardEntry>.self, from: data),
          response.ok, let entry = response.data else {
        if let response = try? decoder.decode(IPCResponse<String>.self, from: data),
           let error = response.error {
            fputs("error: \(error)\n", stderr)
        } else {
            fputs("error: failed to decode response\n", stderr)
        }
        exit(1)
    }

    ClipboardWriter.write(entry.content)
    let preview = entry.content.prefix(60).replacingOccurrences(of: "\n", with: "\\n")
    let truncated = entry.content.count > 60 ? "..." : ""
    print("copied #\(entry.id): \(preview)\(truncated)")

case "help", "--help", "-h":
    print("""
    muninn — clipboard memory

    Usage:
      muninn list [--limit N] [--offset N] [--all] [--json]
      muninn copy <id>
      muninn status [--json]
      muninn help

    Commands:
      list      List recent clipboard entries
      copy      Restore entry to clipboard
      status    Show daemon status
      help      Show this help
    """)

default:
    fputs("unknown command: \(command)\n", stderr)
    fputs("run 'muninn help' for usage\n", stderr)
    exit(1)
}
