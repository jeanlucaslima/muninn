import Testing
import Foundation
import MuninnCore

// Every --json output validated against docs/cli-schemas (§4.11 contract
// rule 1), with optional fields both present and absent.

func expectValid(_ json: String, _ file: String, _ context: String) throws {
    var validator = SchemaValidator()
    let errors = try validator.validate(json, against: file)
    #expect(errors.isEmpty, "\(context) vs \(file): \(errors)")
}

let richItem = ItemSummary(
    id: 3, kind: .html, preview: "hello", byteSize: 12, firstCapturedAt: at, lastCapturedAt: at,
    captureCount: 2, isPinned: true, isProtected: false, sourceBundleID: "com.apple.Safari", sourceAppName: "Safari")
let sparseItem = ItemSummary(
    id: 4, kind: .image, preview: nil, byteSize: nil, firstCapturedAt: at, lastCapturedAt: at,
    captureCount: 1, isPinned: false, isProtected: false, sourceBundleID: nil, sourceAppName: nil)

@Suite("CLI JSON schemas")
struct SchemaTests {
    @Test(arguments: [
        (["status"], IPCMethod.status, "status.json", "rich"),
        (["status"], .status, "status.json", "sparse"),
        (["list"], .list, "page.json", "rich"),
        (["search", "--type", "image"], .search, "page.json", "sparse"),
        (["history", "3"], .history, "history.json", "rich"),
        (["history", "3"], .history, "history.json", "sparse"),
        (["get", "3"], .get, "get.json", "rich"),
        (["get", "4"], .get, "get.json", "sparse"),
        (["copy", "3"], .copy, "item-ref.json", "rich"),
        (["delete", "3"], .delete, "item-ref.json", "rich"),
        (["pause"], .pause, "paused.json", "rich"),
    ])
    func outputsMatchTheirSchemas(arguments: [String], method: IPCMethod, schema: String, variant: String) async throws {
        let rich = variant == "rich"
        var counters = CaptureCounters()
        counters.missedChanges = 1
        let response: Data = switch method {
        case .status:
            ok(StatusInfo(protocolVersion: 2, itemCount: 3, isPaused: false, uptimeSeconds: 9, dataDirectory: "/tmp/x",
                          isDevBuild: true, counters: counters, lastCaptureAt: rich ? at : nil, databaseBytes: 100,
                          helperMemoryBytes: rich ? 5 : nil))
        case .list, .search:
            ok(ItemPage(items: rich ? [richItem, sparseItem] : [], total: rich ? 9 : 0, hasMore: rich))
        case .history:
            ok(HistoryInfo(id: 3, events: [CaptureEventInfo(
                id: 1, capturedAt: at,
                source: rich ? SourceApp(bundleID: "com.apple.Terminal", name: "Terminal", confidence: .high) : .unknown,
                changeCount: rich ? 7 : nil, availableTypes: rich ? ["public.html", "public.utf8-plain-text"] : [])]))
        case .get:
            ok(ItemDetail(
                summary: rich ? richItem : sparseItem,
                representations: rich
                    ? [RepresentationInfo(id: 1, uti: "public.html", role: .primary, byteSize: 12, omitted: nil, assetID: 2, url: nil),
                       RepresentationInfo(id: 2, uti: "public.file-url", role: .alternate, byteSize: nil, omitted: nil, assetID: nil, url: "file:///x")]
                    : [RepresentationInfo(id: 3, uti: "public.png", role: .primary, byteSize: nil, omitted: .size, assetID: nil, url: nil)],
                text: rich ? "hello" : nil))
        case .pause:
            ok(PausedState(isPaused: true))
        default:
            ok(ItemRef(id: 3))
        }
        let helper = try MockHelper([method: response])
        let result = await helper.run(arguments + ["--json"])
        #expect(result.exitCode == 0, "\(arguments): \(result.stderr)")
        try expectValid(result.stdout, schema, "\(arguments) \(variant)")
    }

    @Test func limitsMatchTheirSchema() async throws {
        let result = await runCLI(["status", "--limits", "--json"])
        try expectValid(result.stdout, "limits.json", "status --limits")
    }

    @Test(arguments: [true, false])
    func doctorMatchesItsSchema(helperUp: Bool) async throws {
        let diagnostics = DiagnosticsInfo(
            protocolVersion: MuninnProtocol.version, isDevBuild: true, databaseCheck: ["ok"], searchIndexError: nil,
            staleIndexItems: 0, isPaused: true, lastCaptureAt: at, counters: CaptureCounters(), databaseBytes: 1,
            freeDiskBytes: 2, helperMemoryBytes: 3)
        let result: CLIResult
        if helperUp {
            let helper = try MockHelper([.hello: ok(HelloInfo(protocolVersion: MuninnProtocol.version)), .diagnostics: ok(diagnostics)])
            result = await helper.run(["doctor", "--json"])
        } else {
            result = await runCLI(["doctor", "--json"])
        }
        #expect(result.exitCode == 5)
        try expectValid(result.stdout, "doctor.json", "doctor")
    }

    @Test(arguments: [["get"], ["status"], ["paste", "1"]])
    func errorsMatchTheErrorSchema(arguments: [String]) async throws {
        let result = await runCLI(arguments + ["--json"])
        #expect(result.exitCode != 0)
        #expect(result.stdout.isEmpty)
        try expectValid(result.stderr, "error.json", "\(arguments)")
    }

    @Test func helperErrorsMatchTheErrorSchema() async throws {
        let helper = try MockHelper([.get: failure(.notFound, "item 3 not found")])
        let result = await helper.run(["get", "3", "--json"])
        #expect(result.exitCode == 2)
        try expectValid(result.stderr, "error.json", "not found")
    }

    @Test func everySchemaIsListedAndParses() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: SchemaValidator.directory.path)
            .filter { $0.hasSuffix(".json") }
        let readme = try String(contentsOf: SchemaValidator.directory.appendingPathComponent("README.md"), encoding: .utf8)
        let validator = SchemaValidator()
        for file in files {
            _ = try validator.load(file)
            if file != "common.json" { #expect(readme.contains("`\(file)`"), "\(file) missing from README") }
        }
        #expect(files.count == 10)
    }

    /// The validator must actually reject things, or every test above passes vacuously.
    @Test func validatorRejectsDrift() throws {
        var validator = SchemaValidator()
        #expect(try validator.validate(#"{"schemaVersion":1,"isPaused":true}"#, against: "paused.json").isEmpty)
        #expect(try !validator.validate(#"{"schemaVersion":1,"isPaused":true,"extra":1}"#, against: "paused.json").isEmpty)
        #expect(try !validator.validate(#"{"schemaVersion":1}"#, against: "paused.json").isEmpty)
        #expect(try !validator.validate(#"{"schemaVersion":2,"isPaused":true}"#, against: "paused.json").isEmpty)
        #expect(try !validator.validate(#"{"schemaVersion":1,"isPaused":1}"#, against: "paused.json").isEmpty)
        #expect(try !validator.validate(#"{"schemaVersion":1,"id":0}"#, against: "item-ref.json").isEmpty)
        #expect(try !validator.validate(#"{"schemaVersion":1,"id":1.5}"#, against: "item-ref.json").isEmpty)
        let badTime = #"{"schemaVersion":1,"id":1,"events":[{"id":1,"capturedAt":"2026-11-12","source":{"confidence":"high"},"availableTypes":[]}]}"#
        #expect(try !validator.validate(badTime, against: "history.json").isEmpty)
        let badKind = #"{"schemaVersion":1,"items":[{"id":1,"kind":"spreadsheet","firstCapturedAt":"2026-11-12T00:00:00.000Z","lastCapturedAt":"2026-11-12T00:00:00.000Z","captureCount":1,"isPinned":false,"isProtected":false}],"total":1,"hasMore":false}"#
        #expect(try !validator.validate(badKind, against: "page.json").isEmpty)
    }
}
