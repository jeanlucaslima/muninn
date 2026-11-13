import Foundation
import MuninnCore
import MuninnIPC

// muninn: the CLI (design §4.11). Contract:
// - stdout carries only the successful result; errors go to stderr.
// - With --json, results carry `schemaVersion`; errors are
//   {"schemaVersion":1,"error":{"code","message"}} on stderr, stdout empty.
// - Exit codes: 0 ok · 1 usage · 2 not found · 3 helper unreachable ·
//   5 doctor found problems · 7 internal · 8 incompatible helper · 9 helper busy.
// Not yet: sessions and scopes (§4.12; --no-interactive is accepted and has
// nothing to refuse yet), status --audit (no audit log), and open (needs the
// app bundle's muninn:// URL scheme, gate C).

let cliVersion = "2.0.0-dev"

let usage = """
    muninn: clipboard memory

    Usage:
      muninn status [--limits]
      muninn list [--limit N | --all]
      muninn search [<query>] [--app <name|bundle-id>] [--type <kind|uti>] [--pinned]
                    [--since <date>] [--until <date>] [--limit N | --all]
      muninn history <id>
      muninn get <id>
      muninn copy <id>
      muninn paste <id> [--as <kind|uti>]
      muninn pin <id> | unpin <id> | delete <id>
      muninn pause | resume
      muninn doctor
      muninn debug send          (JSON requests on stdin, one per line)
      muninn help | --version

    Global flags: --json, --no-interactive, --width <cols>
    Kinds: text, rich_text, html, image, pdf, file, other
    Dates: 2026-11-12, 2026-11-12T09:30:00Z, or relative: 30m, 2h, 7d
    """

// MARK: - Arguments

struct Arguments {
    var command = "help"
    var positional: [String] = []
    var values: [String: String] = [:]
    var switches: Set<String> = []

    static let valueFlags: Set<String> = ["--limit", "--app", "--type", "--since", "--until", "--width", "--as"]
    static let switchFlags: Set<String> = [
        "--json", "--all", "--pinned", "--limits", "--no-interactive", "--version", "--help", "-h",
    ]

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

enum CallError: Error {
    case unreachable
    case failed(IPCFailure)

    var exitCode: Int32 {
        switch self {
        case .unreachable: 3
        case .failed(let failure): failure.code.exitCode
        }
    }
    var code: String {
        switch self {
        case .unreachable: "helper_unreachable"
        case .failed(let failure): failure.code.rawValue
        }
    }
    var message: String {
        switch self {
        case .unreachable: "can't reach the Muninn helper. Is Muninn running?"
        case .failed(let failure): failure.message
        }
    }
}

func request<P: Codable & Sendable, T: Codable & Sendable>(_ method: IPCMethod, _ params: P, as type: T.Type) -> Result<T, CallError> {
    let response: IPCResponse<T>
    do {
        response = try IPCClient(socketPath: MuninnPaths.socketPath).call(method, params, as: T.self)
    } catch {
        return .failure(.unreachable)
    }
    if let error = response.error { return .failure(.failed(error)) }
    guard let data = response.data else { return .failure(.failed(IPCFailure(.internal, "the helper sent an empty response"))) }
    return .success(data)
}

func call<P: Codable & Sendable, T: Codable & Sendable>(_ method: IPCMethod, _ params: P, as type: T.Type) -> T {
    switch request(method, params, as: type) {
    case .success(let data): return data
    case .failure(let error): fail(error.exitCode, error.code, error.message)
    }
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

func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
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
    if args.switches.contains("--limits") {
        // The CLI and helper ship together, so the CLI's own values are the helper's.
        struct Limits: Encodable { let limits: [LimitInfo] }
        if jsonMode { printJSON(Limits(limits: MuninnLimits.catalog)); break }
        let width = MuninnLimits.catalog.map(\.name.count).max() ?? 0
        for limit in MuninnLimits.catalog {
            let value = limit.unit == "bytes"
                ? "\(limit.value) bytes (\(ByteCountFormatter.string(fromByteCount: limit.value, countStyle: .memory)))"
                : "\(limit.value) \(limit.unit)"
            print(limit.name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + value)
        }
        break
    }
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

case "paste":
    // Raw bytes of one representation, never truncated, nothing added (§4.11, D10).
    // If a later chunk fails, the bytes already written stay on stdout: check the exit code.
    let id = itemID(args)
    let selector = args.values["--as"]
    if let selector, ItemKind(rawValue: selector) == nil, !selector.contains(".") {
        usageFailure("--as takes a kind (\(ItemKind.allCases.map(\.rawValue).joined(separator: ", "))) or a UTI")
    }
    var first = call(.payload, PayloadRequest(id: id, as: selector), as: PayloadChunk.self)
    let pinned = first.representationID
    var next = 1
    while true {
        do {
            try FileHandle.standardOutput.write(contentsOf: first.data)
        } catch {
            fail(7, "internal", "could not write to stdout: \(error)")
        }
        guard next < first.chunkCount else { break }
        first = call(.payload, PayloadRequest(id: id, representationID: pinned, chunk: next), as: PayloadChunk.self)
        guard first.representationID == pinned, first.chunk == next else {
            fail(7, "internal", "the helper sent the wrong chunk")
        }
        next += 1
    }

case "doctor":
    noPositional()
    runDoctor()

case "debug":
    guard args.positional == ["send"] else { usageFailure("usage: muninn debug send") }
    debugSend()

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

// MARK: - doctor (§4.11)

struct Check: Encodable {
    enum Status: String, Encodable { case pass, fail, skip }
    let id: String
    let title: String
    let status: Status
    let detail: String
    let fix: String?
}

func runDoctor() -> Never {
    var checks: [Check] = []
    func add(_ id: String, _ title: String, _ status: Check.Status, _ detail: String, fix: String? = nil) {
        checks.append(Check(id: id, title: title, status: status, detail: detail, fix: fix))
    }

    // 1–2: packaging. Both depend on the gate C restructure; reported, not faked.
    add("install", "CLI inside a signed Muninn.app", .skip,
        "not checked yet: Muninn isn't packaged as a signed app until gate C")
    add("registration", "Helper registered with SMAppService", .skip,
        "not checked yet: the app still launches the helper as a child process (gate C)")

    // 3–4: reachable, and speaking our protocol.
    let hello = request(.hello, NoParams(), as: HelloInfo.self)
    switch hello {
    case .success:
        add("helper", "Helper reachable", .pass,
            "socket \(MuninnPaths.socketPath); caller identity isn't checked yet (D21, PROOF-002)")
        add("version", "CLI and helper versions compatible", .pass, "protocol version \(MuninnProtocol.version)")
    case .failure(.unreachable):
        add("helper", "Helper reachable", .fail, "nothing answers on \(MuninnPaths.socketPath)",
            fix: "start Muninn (open the menu bar app, or run muninnd)")
    case .failure(.failed(let failure)) where failure.code == .incompatible:
        add("helper", "Helper reachable", .pass, "socket \(MuninnPaths.socketPath)")
        add("version", "CLI and helper versions compatible", .fail, failure.message,
            fix: "restart Muninn so the helper and CLI come from the same build")
    case .failure(let error):
        add("helper", "Helper reachable", .fail, error.message, fix: "restart Muninn")
    }

    let diagnostics: DiagnosticsInfo?
    if case .success = hello {
        switch request(.diagnostics, NoParams(), as: DiagnosticsInfo.self) {
        case .success(let info): diagnostics = info
        case .failure(let error):
            diagnostics = nil
            add("diagnostics", "Helper diagnostics", .fail, error.message, fix: "check the helper's log, then restart Muninn")
        }
    } else {
        diagnostics = nil
    }

    let titles = [
        ("database", "Database opens and passes its integrity check"),
        ("index", "Search index is sound and current"),
        ("jobs", "No failed or quarantined processing jobs"),
        ("capture", "Capture is active"),
        ("storage", "Storage within limits"),
        ("memory", "Memory"),
    ]
    if let d = diagnostics {
        // 5: key and DB. No encryption yet (SQLCipher arrives with PROOF-004).
        if d.databaseCheck == ["ok"] {
            add("database", titles[0].1, .pass, "quick_check ok; not encrypted yet (PROOF-004)")
        } else {
            add("database", titles[0].1, .fail, d.databaseCheck.prefix(3).joined(separator: "; "),
                fix: "quit Muninn and keep a copy of the data directory before anything else")
        }
        // 6: index.
        if let error = d.searchIndexError {
            add("index", titles[1].1, .fail, "integrity-check: \(error)", fix: "restart Muninn to rebuild stale index rows")
        } else if d.staleIndexItems > 0 {
            add("index", titles[1].1, .fail, "\(d.staleIndexItems) item(s) not indexed", fix: "restart Muninn; it re-indexes on start")
        } else {
            add("index", titles[1].1, .pass, "integrity-check ok, every item indexed")
        }
        // 7: jobs.
        add("jobs", titles[2].1, .skip, "not checked yet: there's no processing pipeline until gate D")
        // 8: capture.
        let c = d.counters
        let last = d.lastCaptureAt.map { "last capture \(shortDate($0))" } ?? "nothing captured yet"
        let counters = "observed \(c.observedChanges), missed \(c.missedChanges), dropped \(c.droppedBackpressure), store errors \(c.storeErrors)"
        if d.isPaused {
            add("capture", titles[3].1, .fail, "capture is paused; \(last)", fix: "muninn resume")
        } else if c.storeErrors > 0 {
            add("capture", titles[3].1, .fail, "\(last); \(counters)",
                fix: "the helper couldn't save some captures; check its log (subsystem com.muninn)")
        } else {
            add("capture", titles[3].1, .pass, "\(last); \(counters)")
        }
        // 9: storage. Thresholds aren't defined yet (§4.14), so this reports only.
        let free = d.freeDiskBytes.map { ", \(bytes($0)) free" } ?? ""
        add("storage", titles[4].1, .skip, "database \(bytes(d.databaseBytes))\(free); no thresholds defined yet (§4.14)")
        // 10: memory.
        let memory = d.helperMemoryBytes.map { "helper \(bytes($0))" } ?? "helper unknown"
        add("memory", titles[5].1, .pass, "\(memory); the app's memory isn't reported yet")
    } else {
        for (id, title) in titles {
            add(id, title, .skip, "needs the helper")
        }
    }

    let healthy = !checks.contains { $0.status == .fail }
    if jsonMode {
        struct Report: Encodable { let healthy: Bool; let checks: [Check] }
        printJSON(Report(healthy: healthy, checks: checks))
    } else {
        for check in checks {
            let mark = switch check.status { case .pass: "✓"; case .fail: "✗"; case .skip: "–" }
            print("\(mark) \(check.title): \(check.detail)")
            if let fix = check.fix { print("    fix: \(fix)") }
        }
    }
    exit(healthy ? 0 : 5)
}

// MARK: - debug send (§4.6)

/// Sends each stdin line as one request and prints each reply on its own
/// line. Adds the protocol `version` when a request leaves it out. Replies
/// are printed as received, including errors; exit 1 if a line wasn't a
/// JSON object, 3 if the helper is unreachable.
func debugSend() -> Never {
    let client = IPCClient(socketPath: MuninnPaths.socketPath)
    var sawBadLine = false
    while let line = readLine(strippingNewline: true) {
        if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        guard var object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            writeStderr("muninn: not a JSON object: \(cut(line, 80))\n")
            sawBadLine = true
            continue
        }
        if object["version"] == nil { object["version"] = MuninnProtocol.version }
        let reply: Data
        do {
            reply = try client.send(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        } catch {
            fail(3, "helper_unreachable", "can't reach the Muninn helper. Is Muninn running?")
        }
        print(String(decoding: reply, as: UTF8.self))
    }
    exit(sawBadLine ? 1 : 0)
}
