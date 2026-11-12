import Foundation
import MuninnCore
import MuninnIPC

// muninn: the CLI (design §4.11). Contract:
// - stdout carries only the successful result; errors go to stderr.
// - With --json, results carry `schemaVersion`; errors are
//   {"schemaVersion":1,"error":{"code","message"}} on stderr, stdout empty.
// - Exit codes: 0 ok · 1 usage · 2 not found · 3 helper unreachable ·
//   7 internal · 8 incompatible helper · 9 helper busy.
// Not yet: sessions and scopes (§4.12), paste, open, doctor, debug send.

let cliVersion = "2.0.0-dev"

let usage = """
    muninn: clipboard memory

    Usage:
      muninn status
      muninn list [--limit N | --all]
      muninn search [<query>] [--app <name|bundle-id>] [--type <kind|uti>] [--pinned]
                    [--since <date>] [--until <date>] [--limit N | --all]
      muninn history <id>
      muninn get <id>
      muninn copy <id>
      muninn pin <id> | unpin <id> | delete <id>
      muninn pause | resume
      muninn help | --version

    Global flags: --json, --width <cols>
    Kinds: text, rich_text, html, image, pdf, file, other
    Dates: 2026-11-12, 2026-11-12T09:30:00Z, or relative: 30m, 2h, 7d
    """

// MARK: - Arguments

struct Arguments {
    var command = "help"
    var positional: [String] = []
    var values: [String: String] = [:]
    var switches: Set<String> = []

    static let valueFlags: Set<String> = ["--limit", "--app", "--type", "--since", "--until", "--width"]
    static let switchFlags: Set<String> = ["--json", "--all", "--pinned", "--version", "--help", "-h"]

    init(_ raw: [String]) throws(UsageError) {
        var rest = raw[...]
        var sawCommand = false
        while let arg = rest.popFirst() {
            if arg == "--" {
                positional += rest
                break
            } else if Self.valueFlags.contains(arg) {
                guard let value = rest.popFirst() else { throw UsageError("\(arg) needs a value") }
                values[arg] = value
            } else if Self.switchFlags.contains(arg) {
                switches.insert(arg)
            } else if arg.hasPrefix("--") {
                throw UsageError("unknown flag \(arg)")
            } else if !sawCommand {
                command = arg
                sawCommand = true
            } else {
                positional.append(arg)
            }
        }
    }
}

struct UsageError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - Output

/// Decided before parsing, so even argument errors honor --json.
let jsonMode = CommandLine.arguments.dropFirst().contains("--json")

func writeStderr(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}

/// Ends the process with an error on stderr, never stdout.
func fail(_ exitCode: Int32, _ code: String, _ message: String) -> Never {
    if jsonMode {
        struct ErrorBody: Encodable { let code: String; let message: String }
        struct ErrorOutput: Encodable { let schemaVersion: Int; let error: ErrorBody }
        let output = ErrorOutput(schemaVersion: MuninnProtocol.cliSchemaVersion, error: ErrorBody(code: code, message: message))
        let data = (try? MuninnJSON.encoder().encode(output)) ?? Data()
        writeStderr(String(decoding: data, as: UTF8.self) + "\n")
    } else {
        writeStderr("muninn: \(message)\n")
    }
    exit(exitCode)
}

func usageFailure(_ message: String) -> Never {
    fail(1, "usage", "\(message)\nRun 'muninn help' for usage.")
}

/// Adds `schemaVersion` next to the value's own keys.
struct Versioned<T: Encodable>: Encodable {
    let value: T
    enum Key: String, CodingKey { case schemaVersion }
    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(MuninnProtocol.cliSchemaVersion, forKey: .schemaVersion)
    }
}

func printJSON<T: Encodable>(_ value: T) {
    do {
        let data = try MuninnJSON.encoder(pretty: true).encode(Versioned(value: value))
        print(String(decoding: data, as: UTF8.self))
    } catch {
        fail(7, "internal", "could not encode output: \(error)")
    }
}

// MARK: - Helper calls

func call<P: Codable & Sendable, T: Codable & Sendable>(_ method: IPCMethod, _ params: P, as type: T.Type) -> T {
    let response: IPCResponse<T>
    do {
        response = try IPCClient(socketPath: MuninnPaths.socketPath).call(method, params, as: T.self)
    } catch {
        fail(3, "helper_unreachable", "can't reach the Muninn helper. Is Muninn running?")
    }
    if let error = response.error {
        fail(error.code.exitCode, error.code.rawValue, error.message)
    }
    guard let data = response.data else {
        fail(7, "internal", "the helper sent an empty response")
    }
    return data
}

// MARK: - Parsing helpers

func itemID(_ args: Arguments) -> Int64 {
    guard args.positional.count == 1, let id = Int64(args.positional[0]), id > 0 else {
        usageFailure("muninn \(args.command) needs one item id")
    }
    return id
}

func limit(_ args: Arguments) -> Int? {
    if args.switches.contains("--all") {
        if args.values["--limit"] != nil { usageFailure("use --limit or --all, not both") }
        return nil
    }
    guard let raw = args.values["--limit"] else { return MuninnLimits.defaultResultLimit }
    guard let n = Int(raw), n > 0 else { usageFailure("--limit must be a positive number") }
    return n
}

/// ISO-8601 date or date-time, or relative to now: 30s, 15m, 2h, 7d.
func parseDate(_ raw: String, flag: String) -> Date {
    if let date = MuninnJSON.parseISO8601(raw) { return date }
    if let day = try? Date(raw, strategy: Date.ISO8601FormatStyle(timeZone: .current).year().month().day()) {
        return day
    }
    let units: [Character: Double] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
    if let unit = raw.last, let seconds = units[unit], let n = Double(raw.dropLast()), n >= 0 {
        return Date().addingTimeInterval(-n * seconds)
    }
    usageFailure("\(flag): can't read '\(raw)' as a date")
}

// MARK: - Human output

func terminalWidth(_ args: Arguments) -> Int {
    if let raw = args.values["--width"] {
        guard let n = Int(raw), n >= 20 else { usageFailure("--width must be at least 20") }
        return n
    }
    var size = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 { return Int(size.ws_col) }
    return 100
}

func oneLine(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
}

/// Cuts at `width` characters and marks the cut with `…`.
func cut(_ text: String, _ width: Int) -> String {
    text.count <= width ? text : String(text.prefix(max(0, width - 1))) + "…"
}

func shortDate(_ date: Date) -> String {
    date.formatted(date: .numeric, time: .shortened)
}

func describe(_ item: ItemSummary) -> String {
    let content = item.preview.map(oneLine).flatMap { $0.isEmpty ? nil : $0 }
    switch item.kind {
    case .text: return content ?? "(empty)"
    case .file: return "[file] " + (content ?? "")
    default:
        let size = item.byteSize.map { " " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
        return content.map { "[\(item.kind.rawValue)] \($0)" } ?? "[\(item.kind.rawValue)\(size)]"
    }
}

func printPage(_ page: ItemPage, _ args: Arguments) {
    if page.items.isEmpty {
        writeStderr("No items.\n")
        return
    }
    let width = terminalWidth(args)
    let idWidth = page.items.map { String($0.id).count }.max() ?? 1
    for item in page.items {
        let id = String(item.id).padding(toLength: idWidth, withPad: " ", startingAt: 0)
        let pin = item.isPinned ? " 📌" : ""
        let prefix = "#\(id)  \(shortDate(item.lastCapturedAt))  "
        print(prefix + cut(describe(item), max(10, width - prefix.count - pin.count - 1)) + pin)
    }
    if page.hasMore {
        writeStderr("showing \(page.items.count) of \(page.total); use --limit N or --all for more\n")
    }
}

// MARK: - Commands

let args: Arguments
do {
    args = try Arguments(Array(CommandLine.arguments.dropFirst()))
} catch {
    usageFailure(error.message)
}

if args.switches.contains("--version") {
    print("muninn \(cliVersion)")
    exit(0)
}
if args.switches.contains("--help") || args.switches.contains("-h") {
    print(usage)
    exit(0)
}

func noPositional() {
    if !args.positional.isEmpty { usageFailure("muninn \(args.command) takes no arguments") }
}

switch args.command {
case "help":
    print(usage)

case "status":
    noPositional()
    let status = call(.status, NoParams(), as: StatusInfo.self)
    if jsonMode { printJSON(status); break }
    let c = status.counters
    print("""
        helper:    running\(status.isDevBuild ? " (dev build)" : ""), up \(status.uptimeSeconds)s
        capture:   \(status.isPaused ? "paused" : "active")
        items:     \(status.itemCount)
        data:      \(status.dataDirectory)
        counters:  observed \(c.observedChanges), missed \(c.missedChanges), dropped \(c.droppedBackpressure), \
        too large \(c.omittedBySize), unsupported \(c.skippedUnsupported), self-copies \(c.selfCopies), \
        store errors \(c.storeErrors)
        """)

case "list":
    noPositional()
    let page = call(.list, SearchRequest(limit: limit(args)), as: ItemPage.self)
    if jsonMode { printJSON(page) } else { printPage(page, args) }

case "search":
    var request = SearchRequest(limit: limit(args))
    request.query = args.positional.isEmpty ? nil : args.positional.joined(separator: " ")
    request.app = args.values["--app"]
    request.type = args.values["--type"]
    request.pinned = args.switches.contains("--pinned") ? true : nil
    request.since = args.values["--since"].map { parseDate($0, flag: "--since") }
    request.until = args.values["--until"].map { parseDate($0, flag: "--until") }
    if let type = request.type, ItemKind(rawValue: type) == nil, !type.contains(".") {
        usageFailure("--type takes a kind (\(ItemKind.allCases.map(\.rawValue).joined(separator: ", "))) or a UTI")
    }
    if request.query == nil, request.app == nil, request.type == nil, request.pinned == nil,
       request.since == nil, request.until == nil {
        usageFailure("muninn search needs a query or at least one filter")
    }
    let page = call(.search, request, as: ItemPage.self)
    if jsonMode { printJSON(page) } else { printPage(page, args) }

case "history":
    let history = call(.history, ItemIDParams(id: itemID(args)), as: HistoryInfo.self)
    if jsonMode { printJSON(history); break }
    for event in history.events {
        let source = event.source.name ?? event.source.bundleID ?? "unknown app"
        print("\(shortDate(event.capturedAt))  \(source) (\(event.source.confidence.rawValue))")
    }

case "get":
    let detail = call(.get, ItemIDParams(id: itemID(args)), as: ItemDetail.self)
    if jsonMode { printJSON(detail); break }
    if let text = detail.text {
        // Exact content, never truncated, no newline added.
        FileHandle.standardOutput.write(Data(text.utf8))
    } else {
        print(describe(detail.summary))
        for rep in detail.representations {
            let size = rep.byteSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            let state = rep.omitted.map { "omitted: \($0.rawValue)" } ?? rep.url ?? size ?? ""
            print("  \(rep.uti)  \(rep.role.rawValue)  \(state)")
        }
    }

case "copy":
    let ref = call(.copy, ItemIDParams(id: itemID(args)), as: ItemRef.self)
    if jsonMode { printJSON(ref) } else { print("copied #\(ref.id)") }

case "pin", "unpin", "delete":
    let method = IPCMethod(rawValue: args.command)!
    let ref = call(method, ItemIDParams(id: itemID(args)), as: ItemRef.self)
    let verb = ["pin": "pinned", "unpin": "unpinned", "delete": "deleted"][args.command]!
    if jsonMode { printJSON(ref) } else { print("\(verb) #\(ref.id)") }

case "pause", "resume":
    noPositional()
    let state = call(IPCMethod(rawValue: args.command)!, NoParams(), as: PausedState.self)
    if jsonMode { printJSON(state) } else { print(state.isPaused ? "capture paused" : "capture resumed") }

default:
    usageFailure("unknown command '\(args.command)'")
}
