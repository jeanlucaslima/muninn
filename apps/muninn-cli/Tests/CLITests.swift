import Testing
import Foundation
import MuninnCore
import MuninnIPC

// Runs the real `muninn` binary against a mock helper on a temporary socket
// (MUNINN_SOCKET_PATH, read only in DEBUG builds). No real helper or data.

struct CLIResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

func cliPath() -> String {
    let candidate = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("muninn").path
    return FileManager.default.fileExists(atPath: candidate) ? candidate : ".build/debug/muninn"
}

/// Runs the CLI without blocking a Swift Concurrency thread: the mock
/// helper's handler needs those threads to answer while the CLI waits.
func runCLI(_ arguments: [String], socketPath: String? = nil, timeout: Duration = .seconds(10)) async -> CLIResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: cliPath())
    process.arguments = arguments
    var env = ProcessInfo.processInfo.environment
    // Never fall through to a real helper: default to a socket nobody listens on.
    env["MUNINN_SOCKET_PATH"] = socketPath ?? "/tmp/mn-none-\(UUID().uuidString.prefix(8)).sock"
    process.environment = env

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        process.terminationHandler = { _ in continuation.resume() }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            continuation.resume()
        }
        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }
        _ = watchdog
    }

    return CLIResult(
        stdout: String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
        stderr: String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
        exitCode: process.terminationStatus
    )
}

struct Envelope<P: Decodable>: Decodable { let params: P }

/// Records the requests a mock helper received.
actor RequestLog {
    private(set) var requests: [Data] = []
    func append(_ data: Data) { requests.append(data) }
    func last<P: Decodable>(as type: P.Type) throws -> P? {
        guard let data = requests.last else { return nil }
        return try MuninnJSON.decoder().decode(Envelope<P>.self, from: data).params
    }
    var methods: [String] {
        requests.compactMap { try? MuninnJSON.decoder().decode(IPCRequestHeader.self, from: $0).method }
    }
}

/// A mock helper that answers each method with a canned response.
final class MockHelper {
    let socketPath = "/tmp/mn-cli-\(UUID().uuidString.prefix(8)).sock"
    let log = RequestLog()
    private let server: IPCServer

    init(_ responses: [IPCMethod: Data]) throws {
        let log = self.log
        server = IPCServer(socketPath: socketPath) { data in
            await log.append(data)
            let method = (try? MuninnJSON.decoder().decode(IPCRequestHeader.self, from: data)).flatMap { IPCMethod(rawValue: $0.method) }
            return method.flatMap { responses[$0] } ?? encode(IPCResponse<NoParams>.failure(IPCFailure(.unsupported, "unmocked")))
        }
        try server.start()
    }

    deinit { server.stop() }

    func run(_ arguments: [String]) async -> CLIResult {
        await runCLI(arguments, socketPath: socketPath)
    }
}

func encode<T: Codable & Sendable>(_ response: IPCResponse<T>) -> Data {
    try! MuninnJSON.encoder().encode(response)
}

func ok<T: Codable & Sendable>(_ value: T) -> Data { encode(IPCResponse.success(value)) }
func failure(_ code: IPCErrorCode, _ message: String) -> Data { encode(IPCResponse<NoParams>.failure(IPCFailure(code, message))) }

let at = Date(timeIntervalSince1970: 1_800_000_000)

func item(_ id: Int64, _ preview: String?, kind: ItemKind = .text, pinned: Bool = false, bytes: Int64? = nil) -> ItemSummary {
    ItemSummary(id: id, kind: kind, preview: preview, byteSize: bytes ?? preview.map { Int64($0.utf8.count) },
                firstCapturedAt: at, lastCapturedAt: at, captureCount: 1, isPinned: pinned,
                isProtected: false, sourceBundleID: nil, sourceAppName: "Notes")
}

func json(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

// MARK: - Arguments and transport

@Suite("CLI arguments")
struct ArgumentTests {
    @Test func helpAndVersion() async {
        #expect(await runCLI([]).stdout.contains("Usage:"))
        #expect(await runCLI(["help"]).exitCode == 0)
        let version = await runCLI(["--version"])
        #expect(version.exitCode == 0)
        #expect(version.stdout.hasPrefix("muninn 2."))
    }

    @Test(arguments: [
        ["teleport"], ["get"], ["get", "abc"], ["get", "0"], ["copy"], ["pin", "1", "2"],
        ["list", "--limit", "0"], ["list", "--limit"], ["list", "--limit", "5", "--all"],
        ["list", "--bogus"], ["search"], ["search", "--type", "spreadsheet"],
        ["search", "--since", "yesterday-ish"], ["status", "extra"],
    ])
    func usageErrorsExit1WithNothingOnStdout(arguments: [String]) async {
        let result = await runCLI(arguments)
        #expect(result.exitCode == 1, "\(arguments)")
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("muninn:"))
    }

    @Test func usageErrorInJSONModeIsAnErrorObjectOnStderr() async throws {
        let result = await runCLI(["get", "--json"])
        #expect(result.exitCode == 1)
        #expect(result.stdout.isEmpty)
        let error = try json(result.stderr)["error"] as? [String: Any]
        #expect(error?["code"] as? String == "usage")
    }

    @Test func unreachableHelperExits3() async throws {
        let result = await runCLI(["status"])
        #expect(result.exitCode == 3)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("can't reach"))

        let jsonResult = await runCLI(["status", "--json"])
        #expect(jsonResult.exitCode == 3)
        #expect(try (json(jsonResult.stderr)["error"] as? [String: Any])?["code"] as? String == "helper_unreachable")
    }
}

// MARK: - Commands

@Suite("CLI list and search")
struct ListSearchTests {
    @Test func listPrintsATableAndNoticesTruncation() async throws {
        let helper = try MockHelper([.list: ok(ItemPage(items: [item(2, "second  item\nwith lines", pinned: true), item(1, "first")], total: 5, hasMore: true))])
        let result = await helper.run(["list"])
        #expect(result.exitCode == 0)
        let lines = result.stdout.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("#2"))
        #expect(lines[0].contains("second item with lines"))
        #expect(lines[0].contains("📌"))
        #expect(result.stderr.contains("showing 2 of 5"))
    }

    @Test func previewsAreCutAtWidthAndMarked() async throws {
        let helper = try MockHelper([.list: ok(ItemPage(items: [item(1, String(repeating: "x", count: 300))], total: 1, hasMore: false))])
        let result = await helper.run(["list", "--width", "60"])
        let line = try #require(result.stdout.split(separator: "\n").first)
        #expect(line.count <= 60)
        #expect(line.hasSuffix("…"))
        #expect(result.stderr.isEmpty)
    }

    @Test func listJSONCarriesSchemaVersionTotalAndHasMore() async throws {
        let helper = try MockHelper([.list: ok(ItemPage(items: [item(1, "a")], total: 1, hasMore: false))])
        let result = await helper.run(["list", "--json", "--limit", "7"])
        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty)
        let output = try json(result.stdout)
        #expect(output["schemaVersion"] as? Int == MuninnProtocol.cliSchemaVersion)
        #expect(output["total"] as? Int == 1)
        #expect(output["hasMore"] as? Bool == false)
        let first = try #require((output["items"] as? [[String: Any]])?.first)
        #expect(first["lastCapturedAt"] as? String == "2027-01-15T08:00:00.000Z")
        #expect(try await helper.log.last(as: SearchRequest.self)?.limit == 7)
    }

    @Test func listAllSendsNoLimit() async throws {
        let helper = try MockHelper([.list: ok(ItemPage(items: [], total: 0, hasMore: false))])
        let result = await helper.run(["list", "--all"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("No items"))
        let request = try await helper.log.last(as: SearchRequest.self)
        #expect(request != nil)
        #expect(request?.limit == nil)
    }

    @Test func searchSendsQueryAndFilters() async throws {
        let helper = try MockHelper([.search: ok(ItemPage(items: [item(3, "deploy log")], total: 1, hasMore: false))])
        let result = await helper.run(["search", "deploy", "log", "--app", "Terminal", "--type", "text",
                                 "--pinned", "--since", "2026-11-01T00:00:00Z", "--until", "2d"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("deploy log"))
        let request = try #require(try await helper.log.last(as: SearchRequest.self))
        #expect(request.query == "deploy log")
        #expect(request.app == "Terminal")
        #expect(request.type == "text")
        #expect(request.pinned == true)
        #expect(request.since == MuninnJSON.parseISO8601("2026-11-01T00:00:00Z"))
        let until = try #require(request.until)
        #expect(abs(until.timeIntervalSinceNow + 2 * 86400) < 60)
    }

    @Test func filterOnlySearchIsAllowed() async throws {
        let helper = try MockHelper([.search: ok(ItemPage(items: [], total: 0, hasMore: false))])
        #expect(await helper.run(["search", "--type", "image"]).exitCode == 0)
        #expect(try await helper.log.last(as: SearchRequest.self)?.query == nil)
    }

    @Test func nonTextItemsAreDescribed() async throws {
        let helper = try MockHelper([.list: ok(ItemPage(items: [
            item(1, nil, kind: .image, bytes: 2048), item(2, "report.pdf (+2 more)", kind: .file),
        ], total: 2, hasMore: false))])
        let out = await helper.run(["list"]).stdout
        #expect(out.contains("[image 2 KB]"))
        #expect(out.contains("[file] report.pdf (+2 more)"))
    }
}

@Suite("CLI item commands")
struct ItemCommandTests {
    let detail = ItemDetail(
        summary: item(5, "line one"),
        representations: [RepresentationInfo(id: 1, uti: "public.utf8-plain-text", role: .primary, byteSize: 17, omitted: nil, assetID: nil, url: nil)],
        text: "line one\nline two")

    @Test func getPrintsExactContentWithNoAddedNewline() async throws {
        let helper = try MockHelper([.get: ok(detail)])
        let result = await helper.run(["get", "5"])
        #expect(result.exitCode == 0)
        #expect(result.stdout == "line one\nline two")
    }

    @Test func getJSONIsTheFullDetail() async throws {
        let helper = try MockHelper([.get: ok(detail)])
        let output = try json(await helper.run(["get", "5", "--json"]).stdout)
        #expect(output["text"] as? String == "line one\nline two")
        #expect(output["schemaVersion"] as? Int == 1)
        #expect((output["representations"] as? [[String: Any]])?.first?["uti"] as? String == "public.utf8-plain-text")
    }

    @Test func getOfANonTextItemListsRepresentations() async throws {
        let image = ItemDetail(summary: item(6, nil, kind: .image, bytes: 10),
                               representations: [RepresentationInfo(id: 1, uti: "public.png", role: .primary, byteSize: nil, omitted: .size, assetID: nil, url: nil)],
                               text: nil)
        let helper = try MockHelper([.get: ok(image)])
        let out = await helper.run(["get", "6"]).stdout
        #expect(out.contains("[image"))
        #expect(out.contains("public.png  primary  omitted: size"))
    }

    @Test func notFoundExits2WithStderrOnly() async throws {
        let helper = try MockHelper([.get: failure(.notFound, "item 9 not found")])
        let human = await helper.run(["get", "9"])
        #expect(human.exitCode == 2)
        #expect(human.stdout.isEmpty)
        #expect(human.stderr == "muninn: item 9 not found\n")

        let machine = await helper.run(["get", "9", "--json"])
        #expect(machine.exitCode == 2)
        #expect(machine.stdout.isEmpty)
        let error = try json(machine.stderr)["error"] as? [String: Any]
        #expect(error?["code"] as? String == "not_found")
    }

    @Test(arguments: [
        (["copy", "4"], IPCMethod.copy, "copied #4"),
        (["pin", "4"], .pin, "pinned #4"),
        (["unpin", "4"], .unpin, "unpinned #4"),
        (["delete", "4"], .delete, "deleted #4"),
    ])
    func itemCommands(arguments: [String], method: IPCMethod, expected: String) async throws {
        let helper = try MockHelper([method: ok(ItemRef(id: 4))])
        let result = await helper.run(arguments)
        #expect(result.exitCode == 0)
        #expect(result.stdout == expected + "\n")
        #expect(await helper.log.methods == [method.rawValue])
        #expect(try await helper.log.last(as: ItemIDParams.self) == ItemIDParams(id: 4))

        let jsonOut = try json(await helper.run(arguments + ["--json"]).stdout)
        #expect(jsonOut["id"] as? Int == 4)
    }

    @Test func historyListsEvents() async throws {
        let events = [CaptureEventInfo(id: 1, capturedAt: at, source: SourceApp(bundleID: "com.apple.Safari", name: "Safari", confidence: .high), changeCount: 3, availableTypes: ["public.html"])]
        let helper = try MockHelper([.history: ok(HistoryInfo(id: 5, events: events))])
        let result = await helper.run(["history", "5"])
        #expect(result.stdout.contains("Safari (high)"))
        let output = try json(await helper.run(["history", "5", "--json"]).stdout)
        #expect((output["events"] as? [[String: Any]])?.count == 1)
    }
}

@Suite("CLI helper state")
struct HelperStateTests {
    @Test func statusShowsCounters() async throws {
        var counters = CaptureCounters()
        counters.missedChanges = 4
        let status = StatusInfo(protocolVersion: 2, itemCount: 12, isPaused: false, uptimeSeconds: 60,
                                dataDirectory: "/tmp/x", isDevBuild: true, counters: counters)
        let helper = try MockHelper([.status: ok(status)])
        let out = await helper.run(["status"]).stdout
        #expect(out.contains("items:     12"))
        #expect(out.contains("missed 4"))
        #expect(out.contains("(dev build)"))
        let output = try json(await helper.run(["status", "--json"]).stdout)
        #expect((output["counters"] as? [String: Any])?["missedChanges"] as? Int == 4)
    }

    @Test func pauseAndResume() async throws {
        let helper = try MockHelper([.pause: ok(PausedState(isPaused: true)), .resume: ok(PausedState(isPaused: false))])
        #expect(await helper.run(["pause"]).stdout == "capture paused\n")
        #expect(await helper.run(["resume"]).stdout == "capture resumed\n")
    }

    @Test(arguments: [(IPCErrorCode.internal, Int32(7)), (.incompatible, 8), (.busy, 9), (.invalidRequest, 1)])
    func helperErrorsMapToExitCodes(code: IPCErrorCode, exit: Int32) async throws {
        let helper = try MockHelper([.status: failure(code, "boom")])
        let result = await helper.run(["status"])
        #expect(result.exitCode == exit)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("boom"))
    }

    @Test func garbledResponseIsIncompatible() async throws {
        let helper = try MockHelper([.status: Data("{\"version\":1}".utf8)])
        #expect(await helper.run(["status"]).exitCode == 8)
    }
}
