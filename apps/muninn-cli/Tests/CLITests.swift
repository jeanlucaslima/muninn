import Testing
import Foundation
@testable import MuninnCore
@testable import MuninnIPC

// MARK: - Sendable Helpers

final class SendableBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

// MARK: - Test Helpers

/// Runs the CLI binary with the given arguments, connecting to a mock IPC server.
struct CLIResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

func buildProductPath() -> String {
    // Find the built binary relative to the test bundle
    let fm = FileManager.default
    // Walk up from the test executable to find the products directory
    let testBundle = Bundle.main.executableURL!.deletingLastPathComponent()
    let candidate = testBundle.appendingPathComponent("muninn").path
    if fm.fileExists(atPath: candidate) {
        return candidate
    }
    // Fallback: try swift build output
    return ".build/debug/muninn"
}

func runCLI(_ arguments: [String], socketPath: String? = nil, timeout: TimeInterval = 5) -> CLIResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: buildProductPath())
    process.arguments = arguments

    var env = ProcessInfo.processInfo.environment
    if let socketPath = socketPath {
        env["MUNINN_SOCKET_PATH"] = socketPath
    }
    process.environment = env

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try! process.run()

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning {
        process.terminate()
    }
    process.waitUntilExit()

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

    return CLIResult(
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? "",
        exitCode: process.terminationStatus
    )
}

/// Creates a mock IPC server that responds with the given handler.
/// Returns the socket path and server instance (caller must stop it).
func makeMockServer(handler: @escaping @Sendable (IPCRequest) throws -> Data) throws -> (String, IPCServer) {
    let socketPath = "/tmp/mn-\(UUID().uuidString.prefix(8)).sock"
    let server = IPCServer(socketPath: socketPath, handler: handler)
    try server.start()
    Thread.sleep(forTimeInterval: 0.1) // Let server start
    return (socketPath, server)
}

/// Encodes a success response matching the daemon's encoding.
func encodeSuccess<T: Codable & Sendable>(_ data: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(IPCResponse.success(data))
}

/// Encodes an error response.
func encodeError(_ detail: IPCErrorDetail) throws -> Data {
    let encoder = JSONEncoder()
    return try encoder.encode(IPCResponse<String>.failure(detail))
}

/// Creates a test clipboard entry.
func makeEntry(
    id: Int64, content: String, isPinned: Bool = false,
    kind: EntryKind = .text, metadata: EntryMetadata? = nil
) -> ClipboardEntry {
    ClipboardEntry(
        id: id,
        content: content,
        contentHash: "testhash\(id)",
        createdAt: Date(timeIntervalSince1970: 1743200000 + Double(id)),
        isPinned: isPinned,
        kind: kind,
        metadata: metadata
    )
}

// MARK: - Argument Parsing

@Suite("CLI Argument Parsing")
struct ArgumentParsingTests {
    @Test("Missing command shows help")
    func missingCommand() {
        let result = runCLI(["help"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("muninn — clipboard memory"))
        #expect(result.stdout.contains("list"))
        #expect(result.stdout.contains("search"))
    }

    @Test("Unknown command fails with error")
    func unknownCommand() {
        let result = runCLI(["nonexistent"])
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("unknown command: nonexistent"))
    }

    @Test("get without id fails")
    func getMissingId() {
        let result = runCLI(["get"])
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("usage:"))
    }

    @Test("copy without id fails")
    func copyMissingId() {
        let result = runCLI(["copy"])
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("usage:"))
    }

    @Test("delete without id fails")
    func deleteMissingId() {
        let result = runCLI(["delete"])
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("usage:"))
    }

    @Test("pin without id fails")
    func pinMissingId() {
        let result = runCLI(["pin"])
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("usage:"))
    }

    @Test("unpin without id fails")
    func unpinMissingId() {
        let result = runCLI(["unpin"])
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("usage:"))
    }

    @Test("search without query fails")
    func searchMissingQuery() {
        let result = runCLI(["search"])
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("usage:"))
    }

    @Test("get with non-numeric id fails")
    func getNonNumericId() {
        let result = runCLI(["get", "abc"])
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("usage:"))
    }
}

// MARK: - Daemon Unavailable

@Suite("CLI Daemon Unavailable")
struct DaemonUnavailableTests {
    @Test("Error when daemon is not running")
    func daemonNotRunning() {
        let fakePath = NSTemporaryDirectory() + "muninn-no-daemon-\(UUID().uuidString).sock"
        let result = runCLI(["list"], socketPath: fakePath)
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("muninnd is not running"))
    }
}

// MARK: - List Command

@Suite("CLI List Command")
struct ListTests {
    @Test("list human output shows entries")
    func listHuman() throws {
        let entries = [makeEntry(id: 2, content: "second"), makeEntry(id: 1, content: "first")]
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(ListResponseData(entries: entries, total: 2))
        }
        defer { server.stop() }

        let result = runCLI(["list"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("#"))
        #expect(result.stdout.contains("second"))
        #expect(result.stdout.contains("first"))
        #expect(result.stdout.contains("2 total entries"))
        // Should not contain JSON markers
        #expect(!result.stdout.contains("{"))
    }

    @Test("list --json returns valid JSON")
    func listJson() throws {
        let entries = [makeEntry(id: 1, content: "hello")]
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(ListResponseData(entries: entries, total: 1))
        }
        defer { server.stop() }

        let result = runCLI(["list", "--json"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as! [String: Any]
        #expect(json["ok"] as? Bool == true)
        let data = json["data"] as! [String: Any]
        let jsonEntries = data["entries"] as! [[String: Any]]
        #expect(jsonEntries.count == 1)
        #expect(jsonEntries[0]["content"] as? String == "hello")
    }

    @Test("list empty shows no entries message")
    func listEmpty() throws {
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(ListResponseData(entries: [], total: 0))
        }
        defer { server.stop() }

        let result = runCLI(["list"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("No clipboard entries yet."))
    }

    @Test("list preview truncation")
    func listPreviewTruncation() throws {
        let longContent = String(repeating: "a", count: 200)
        let entries = [makeEntry(id: 1, content: longContent)]
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(ListResponseData(entries: entries, total: 1))
        }
        defer { server.stop() }

        let result = runCLI(["list"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        // Preview should be truncated with ellipsis
        #expect(result.stdout.contains("\u{2026}"))
        // Full content should NOT appear in human output
        #expect(!result.stdout.contains(longContent))
    }

    @Test("list --json returns full content without truncation")
    func listJsonFullContent() throws {
        let longContent = String(repeating: "x", count: 200)
        let entries = [makeEntry(id: 1, content: longContent)]
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(ListResponseData(entries: entries, total: 1))
        }
        defer { server.stop() }

        let result = runCLI(["list", "--json"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains(longContent))
    }

    @Test("list shows pinned indicator")
    func listPinnedIndicator() throws {
        let entries = [makeEntry(id: 1, content: "pinned entry", isPinned: true)]
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(ListResponseData(entries: entries, total: 1))
        }
        defer { server.stop() }

        let result = runCLI(["list"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("[pinned]"))
    }

    @Test("list whitespace normalization")
    func listWhitespaceNormalization() throws {
        let entries = [makeEntry(id: 1, content: "hello\n  world\t\ttabs")]
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(ListResponseData(entries: entries, total: 1))
        }
        defer { server.stop() }

        let result = runCLI(["list"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("hello world tabs"))
    }

    @Test("list --limit is passed to request")
    func listLimit() throws {
        let box = SendableBox<Int?>()
        let (socketPath, server) = try makeMockServer { request in
            if case .list(let params) = request.params {
                box.value = params.limit
            }
            return try encodeSuccess(ListResponseData(entries: [], total: 0))
        }
        defer { server.stop() }

        _ = runCLI(["list", "--limit", "5"], socketPath: socketPath)
        #expect(box.value == 5)
    }
}

// MARK: - Search Command

@Suite("CLI Search Command")
struct SearchTests {
    @Test("search human output shows matching entries")
    func searchHuman() throws {
        let entries = [makeEntry(id: 3, content: "hello world")]
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(SearchResponseData(entries: entries))
        }
        defer { server.stop() }

        let result = runCLI(["search", "hello"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("hello world"))
        #expect(result.stdout.contains("1 matching entries"))
    }

    @Test("search --json returns valid JSON")
    func searchJson() throws {
        let entries = [makeEntry(id: 1, content: "test")]
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(SearchResponseData(entries: entries))
        }
        defer { server.stop() }

        let result = runCLI(["search", "test", "--json"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as! [String: Any]
        #expect(json["ok"] as? Bool == true)
    }

    @Test("search no results shows message")
    func searchNoResults() throws {
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(SearchResponseData(entries: []))
        }
        defer { server.stop() }

        let result = runCLI(["search", "nonexistent"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("No entries matching"))
    }
}

// MARK: - Get Command

@Suite("CLI Get Command")
struct GetTests {
    @Test("get returns exact full content")
    func getFullContent() throws {
        let content = "line 1\nline 2\nline 3"
        let entry = makeEntry(id: 5, content: content)
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(entry)
        }
        defer { server.stop() }

        let result = runCLI(["get", "5"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        #expect(result.stdout == content) // No trailing newline
    }

    @Test("get --json returns full entry as JSON")
    func getJson() throws {
        let entry = makeEntry(id: 5, content: "full content here")
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(entry)
        }
        defer { server.stop() }

        let result = runCLI(["get", "5", "--json"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as! [String: Any]
        #expect(json["ok"] as? Bool == true)
        let data = json["data"] as! [String: Any]
        #expect(data["content"] as? String == "full content here")
    }

    @Test("get unknown id fails")
    func getUnknownId() throws {
        let (socketPath, server) = try makeMockServer { _ in
            try encodeError(.notFound("entry not found: 999"))
        }
        defer { server.stop() }

        let result = runCLI(["get", "999"], socketPath: socketPath)
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("entry not found: 999"))
    }
}

// MARK: - Copy Command

@Suite("CLI Copy Command")
struct CopyTests {
    @Test("copy human output")
    func copyHuman() throws {
        let entry = makeEntry(id: 7, content: "copied content")
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(entry)
        }
        defer { server.stop() }

        let result = runCLI(["copy", "7"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("copied #7"))
    }

    @Test("copy --json returns full entry")
    func copyJson() throws {
        let entry = makeEntry(id: 7, content: "copied content")
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(entry)
        }
        defer { server.stop() }

        let result = runCLI(["copy", "7", "--json"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as! [String: Any]
        #expect(json["ok"] as? Bool == true)
        let data = json["data"] as! [String: Any]
        #expect(data["content"] as? String == "copied content")
    }
}

// MARK: - Delete Command

@Suite("CLI Delete Command")
struct DeleteTests {
    @Test("delete human output")
    func deleteHuman() throws {
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(["id": Int64(10)])
        }
        defer { server.stop() }

        let result = runCLI(["delete", "10"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("deleted #10"))
    }

    @Test("delete --json returns response")
    func deleteJson() throws {
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(["id": Int64(10)])
        }
        defer { server.stop() }

        let result = runCLI(["delete", "10", "--json"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as! [String: Any]
        #expect(json["ok"] as? Bool == true)
    }

    @Test("delete unknown id fails")
    func deleteUnknownId() throws {
        let (socketPath, server) = try makeMockServer { _ in
            try encodeError(.notFound("entry not found: 999"))
        }
        defer { server.stop() }

        let result = runCLI(["delete", "999"], socketPath: socketPath)
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("entry not found"))
    }
}

// MARK: - Pin Command

@Suite("CLI Pin Command")
struct PinTests {
    @Test("pin human output")
    func pinHuman() throws {
        let entry = makeEntry(id: 3, content: "pinned", isPinned: true)
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(entry)
        }
        defer { server.stop() }

        let result = runCLI(["pin", "3"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("pinned #3"))
    }

    @Test("pin --json returns full entry")
    func pinJson() throws {
        let entry = makeEntry(id: 3, content: "pinned content", isPinned: true)
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(entry)
        }
        defer { server.stop() }

        let result = runCLI(["pin", "3", "--json"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as! [String: Any]
        #expect(json["ok"] as? Bool == true)
        let data = json["data"] as! [String: Any]
        #expect(data["content"] as? String == "pinned content")
        #expect(data["isPinned"] as? Bool == true)
    }

    @Test("pin unknown id fails")
    func pinUnknownId() throws {
        let (socketPath, server) = try makeMockServer { _ in
            try encodeError(.notFound("entry not found: 999"))
        }
        defer { server.stop() }

        let result = runCLI(["pin", "999"], socketPath: socketPath)
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("entry not found"))
    }
}

// MARK: - Unpin Command

@Suite("CLI Unpin Command")
struct UnpinTests {
    @Test("unpin human output")
    func unpinHuman() throws {
        let entry = makeEntry(id: 3, content: "unpinned", isPinned: false)
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(entry)
        }
        defer { server.stop() }

        let result = runCLI(["unpin", "3"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("unpinned #3"))
    }

    @Test("unpin --json returns full entry")
    func unpinJson() throws {
        let entry = makeEntry(id: 3, content: "unpinned content", isPinned: false)
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(entry)
        }
        defer { server.stop() }

        let result = runCLI(["unpin", "3", "--json"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as! [String: Any]
        #expect(json["ok"] as? Bool == true)
        let data = json["data"] as! [String: Any]
        #expect(data["isPinned"] as? Bool == false)
    }
}

// MARK: - Pause Command

@Suite("CLI Pause Command")
struct PauseTests {
    @Test("pause human output")
    func pauseHuman() throws {
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(["paused": true])
        }
        defer { server.stop() }

        let result = runCLI(["pause"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("clipboard watching paused"))
    }

    @Test("pause --json returns response")
    func pauseJson() throws {
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(["paused": true])
        }
        defer { server.stop() }

        let result = runCLI(["pause", "--json"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as! [String: Any]
        #expect(json["ok"] as? Bool == true)
        let data = json["data"] as! [String: Any]
        #expect(data["paused"] as? Bool == true)
    }
}

// MARK: - Resume Command

@Suite("CLI Resume Command")
struct ResumeTests {
    @Test("resume human output")
    func resumeHuman() throws {
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(["paused": false])
        }
        defer { server.stop() }

        let result = runCLI(["resume"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("clipboard watching resumed"))
    }

    @Test("resume --json returns response")
    func resumeJson() throws {
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(["paused": false])
        }
        defer { server.stop() }

        let result = runCLI(["resume", "--json"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as! [String: Any]
        #expect(json["ok"] as? Bool == true)
        let data = json["data"] as! [String: Any]
        #expect(data["paused"] as? Bool == false)
    }
}

// MARK: - Status Command

@Suite("CLI Status Command")
struct StatusTests {
    @Test("status human output")
    func statusHuman() throws {
        let status = StatusResponseData(
            running: true, entryCount: 42, dbPath: "/tmp/test.db",
            uptimeSeconds: 3661, isPaused: false
        )
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(status)
        }
        defer { server.stop() }

        let result = runCLI(["status"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("running:  true"))
        #expect(result.stdout.contains("paused:   false"))
        #expect(result.stdout.contains("entries:  42"))
        #expect(result.stdout.contains("1h 1m 1s"))
        #expect(result.stdout.contains("/tmp/test.db"))
    }

    @Test("status --json returns full response")
    func statusJson() throws {
        let status = StatusResponseData(
            running: true, entryCount: 10, dbPath: "/tmp/test.db",
            uptimeSeconds: 100, isPaused: true
        )
        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(status)
        }
        defer { server.stop() }

        let result = runCLI(["status", "--json"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as! [String: Any]
        #expect(json["ok"] as? Bool == true)
        let data = json["data"] as! [String: Any]
        #expect(data["entryCount"] as? Int == 10)
        #expect(data["isPaused"] as? Bool == true)
    }
}

// MARK: - Error Handling

@Suite("CLI Error Handling")
struct ErrorHandlingTests {
    @Test("server error returns non-zero exit and clean message")
    func serverErrorClean() throws {
        let (socketPath, server) = try makeMockServer { _ in
            try encodeError(.invalidRequest("limit must be greater than 0"))
        }
        defer { server.stop() }

        let result = runCLI(["list", "--limit", "-1"], socketPath: socketPath)
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("limit must be greater than 0"))
        #expect(result.stdout.isEmpty)
    }

    @Test("not found error in JSON mode returns structured error")
    func notFoundJsonError() throws {
        let (socketPath, server) = try makeMockServer { _ in
            try encodeError(.notFound("entry not found: 42"))
        }
        defer { server.stop() }

        // In JSON mode, the raw response is printed (which includes the error)
        let result = runCLI(["get", "42", "--json"], socketPath: socketPath)
        #expect(result.exitCode == 0) // JSON mode prints raw response
        let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as! [String: Any]
        #expect(json["ok"] as? Bool == false)
        #expect((json["error"] as? String)?.contains("entry not found") == true)
    }

    @Test("JSON output for error includes errorDetail")
    func jsonErrorDetail() throws {
        let (socketPath, server) = try makeMockServer { _ in
            try encodeError(.invalidRequest("query must not be empty"))
        }
        defer { server.stop() }

        let result = runCLI(["search", "x", "--json"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as! [String: Any]
        #expect(json["ok"] as? Bool == false)
        let detail = json["errorDetail"] as! [String: Any]
        #expect(detail["category"] as? String == "invalid_request")
    }
}

// MARK: - Non-Text Entries

@Suite("CLI Non-Text Entries")
struct NonTextEntryTests {
    @Test("List shows placeholders for non-text entries")
    func listNonTextPlaceholders() throws {
        let entries = [
            makeEntry(id: 3, content: "<image 1440\u{00D7}900>", kind: .image,
                      metadata: EntryMetadata(width: 1440, height: 900)),
            makeEntry(id: 2, content: "<file: report.pdf>", kind: .file,
                      metadata: EntryMetadata(name: "report.pdf")),
            makeEntry(id: 1, content: "hello world", kind: .text),
        ]

        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(ListResponseData(entries: entries, total: 3))
        }
        defer { server.stop() }

        let result = runCLI(["list"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("<image 1440\u{00D7}900>"))
        #expect(result.stdout.contains("<file: report.pdf>"))
        #expect(result.stdout.contains("hello world"))
    }

    @Test("List JSON includes kind and metadata")
    func listJsonIncludesKind() throws {
        let entry = makeEntry(id: 1, content: "<image>", kind: .image,
                              metadata: EntryMetadata(width: 800, height: 600))

        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(ListResponseData(entries: [entry], total: 1))
        }
        defer { server.stop() }

        let result = runCLI(["list", "--json"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("\"kind\":\"image\""))
    }

    @Test("Get non-text entry shows placeholder")
    func getNonText() throws {
        let entry = makeEntry(id: 1, content: "<files: 3 items>", kind: .files,
                              metadata: EntryMetadata(count: 3))

        let (socketPath, server) = try makeMockServer { _ in
            try encodeSuccess(entry)
        }
        defer { server.stop() }

        let result = runCLI(["get", "1"], socketPath: socketPath)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("<files: 3 items>"))
    }

    @Test("Copy non-text entry fails with error")
    func copyNonText() throws {
        let (socketPath, server) = try makeMockServer { _ in
            try encodeError(.unsupported("cannot copy this item yet"))
        }
        defer { server.stop() }

        let result = runCLI(["copy", "1"], socketPath: socketPath)
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("cannot copy this item yet"))
    }
}

// MARK: - JSON Consistency

@Suite("CLI JSON Consistency")
struct JSONConsistencyTests {
    @Test("all commands with --json produce valid JSON with ok field")
    func allCommandsJsonValid() throws {
        let entry = makeEntry(id: 1, content: "test")

        let handlers: [(String, [String], @Sendable (IPCRequest) throws -> Data)] = [
            ("list", ["list", "--json"], { _ in try encodeSuccess(ListResponseData(entries: [entry], total: 1)) }),
            ("search", ["search", "x", "--json"], { _ in try encodeSuccess(SearchResponseData(entries: [entry])) }),
            ("get", ["get", "1", "--json"], { _ in try encodeSuccess(entry) }),
            ("copy", ["copy", "1", "--json"], { _ in try encodeSuccess(entry) }),
            ("delete", ["delete", "1", "--json"], { _ in try encodeSuccess(["id": Int64(1)]) }),
            ("pin", ["pin", "1", "--json"], { _ in try encodeSuccess(entry) }),
            ("unpin", ["unpin", "1", "--json"], { _ in try encodeSuccess(entry) }),
            ("pause", ["pause", "--json"], { _ in try encodeSuccess(["paused": true]) }),
            ("resume", ["resume", "--json"], { _ in try encodeSuccess(["paused": false]) }),
            ("status", ["status", "--json"], { _ in
                try encodeSuccess(StatusResponseData(
                    running: true, entryCount: 0, dbPath: "/tmp/t.db",
                    uptimeSeconds: 0, isPaused: false
                ))
            }),
        ]

        for (name, cliArgs, handler) in handlers {
            let (socketPath, server) = try makeMockServer(handler: handler)
            defer { server.stop() }

            let result = runCLI(cliArgs, socketPath: socketPath)
            #expect(result.exitCode == 0, "command '\(name)' failed with exit code \(result.exitCode)")

            let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
            #expect(json != nil, "command '\(name)' did not produce valid JSON")
            #expect(json?["ok"] as? Bool == true, "command '\(name)' did not have ok: true")
        }
    }
}
