import Testing
import Foundation
import MuninnCore
import MuninnStore
@testable import MuninnSearch

// SearchService over a temporary v2 store. Nothing touches real user data.

final class Fixture {
    let directory: URL
    let writer: StoreWriter
    let search: SearchService
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muninn-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("muninn.db").path
        writer = try StoreWriter(path: path)
        search = SearchService(pool: try ReaderPool(path: path))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Captures plain text `ago` seconds before `now`.
    @discardableResult
    func add(_ s: String, ago: TimeInterval = 3600, app: String? = nil, bundleID: String? = nil) async throws -> Int64 {
        try await writer.capture(CaptureInput(
            capturedAt: now.addingTimeInterval(-ago),
            source: SourceApp(bundleID: bundleID, name: app, confidence: bundleID == nil ? .low : .high),
            changeCount: nil,
            availableTypes: ["public.utf8-plain-text"],
            representations: [RepresentationInput(uti: "public.utf8-plain-text", role: .primary, payload: .text(s))]
        )).itemID
    }

    @discardableResult
    func addImage(ago: TimeInterval = 3600, seed: UInt8 = 1) async throws -> Int64 {
        try await writer.capture(CaptureInput(
            capturedAt: now.addingTimeInterval(-ago),
            source: .unknown, changeCount: nil, availableTypes: ["public.png"],
            representations: [RepresentationInput(uti: "public.png", role: .primary, payload: .data(Data([seed, 2, 3])))]
        )).itemID
    }

    func find(_ query: String?, _ configure: (inout SearchRequest) -> Void = { _ in }) async throws -> ItemPage {
        var request = SearchRequest(query: query)
        configure(&request)
        return try await search.search(request, now: now)
    }

    func ids(_ query: String?, _ configure: (inout SearchRequest) -> Void = { _ in }) async throws -> [Int64] {
        try await find(query, configure).items.map(\.id)
    }
}

@Suite("SearchService: relevance cases (§4.7)")
struct RelevanceTests {
    /// A small mixed PT/EN and code corpus with distractors around each target.
    func corpus() async throws -> (Fixture, [String: Int64]) {
        let f = try Fixture()
        var ids: [String: Int64] = [:]
        try await f.add("A ação foi concluída com sucesso")
        ids["acao"] = try await f.add("Ação necessária: revisar o contrato")
        try await f.add("acacia trees grow in dry climates")
        ids["webhook"] = try await f.add("export async function stripeWebhookHandler(req, res) {}")
        try await f.add("web hooks are a pattern")
        ids["url"] = try await f.add("https://billing.example.com/api/v2/invoices/inv_8f3a2c?expand=lines")
        try await f.add("https://example.com/api/v1/users")
        ids["uuid"] = try await f.add("request id 3f2b8c1e-9d4a-4e6b-8f21-7c5d9e0a1b2c failed")
        try await f.add("request id 11111111-2222-3333-4444-555555555555 ok")
        ids["func"] = try await f.add("func handle(_ event: Event) async throws {\n  try await process(event)\n}")
        try await f.add("handle the edge cases first")
        ids["pt-in-en"] = try await f.add("We need to ship the feature before the reunião on Friday")
        try await f.add("We need to ship the feature before the meeting on Friday")
        for i in 0..<30 {
            try await f.add("noise item \(i) about deployments and logs", ago: Double(i) * 60)
        }
        return (f, ids)
    }

    @Test(arguments: [
        ("acao", "acao"),
        ("webhook", "webhook"),
        ("/api/v2/inv", "url"),
        ("1e-9d4a-", "uuid"),
        ("func handle(", "func"),
        ("reuniao", "pt-in-en"),
    ])
    func expectedItemIsInTopFive(query: String, key: String) async throws {
        let (f, ids) = try await corpus()
        let top = try await f.ids(query) { $0.limit = 5 }
        #expect(top.contains(try #require(ids[key])), "'\(query)' → top 5 was \(top)")
    }

    @Test func betterMatchOutranksMoreRecentWeakerMatch() async throws {
        let f = try Fixture()
        let strong = try await f.add("invoice invoice invoice overdue", ago: 30 * 24 * 3600)
        let weak = try await f.add("a long note that mentions an invoice once among many many other words here", ago: 60)
        let ids = try await f.ids("invoice overdue")
        #expect(ids.first == strong)
        #expect(!ids.contains(weak), "weak item lacks 'overdue', so it isn't a match at all")
    }

    @Test func recencyBreaksTiesBetweenEqualMatches() async throws {
        let f = try Fixture()
        let old = try await f.add("same words here", ago: 10 * 24 * 3600)
        let new = try await f.add("same words here ", ago: 60)
        #expect(try await f.ids("same words") == [new, old])
    }
}

@Suite("SearchService: query handling")
struct QueryTests {
    @Test func shortTermsUseTheFallback() async throws {
        let f = try Fixture()
        let hit = try await f.add("go build ./...")
        try await f.add("nothing relevant")
        #expect(try await f.ids("go") == [hit])
        #expect(try await f.ids("go build") == [hit])
    }

    @Test func emptyQueryListsByRecency() async throws {
        let f = try Fixture()
        let a = try await f.add("a", ago: 300)
        let b = try await f.add("b", ago: 100)
        let c = try await f.add("c", ago: 200)
        #expect(try await f.ids(nil) == [b, c, a])
        #expect(try await f.ids("   ") == [b, c, a])
        #expect(try await f.search.list(limit: nil).items.map(\.id) == [b, c, a])
    }

    @Test func specialCharactersDontBreakTheQuery() async throws {
        let f = try Fixture()
        let hit = try await f.add(#"say "hello" * NEAR(x) ^ 100% done_ok"#)
        for q in [#""hello""#, "NEAR(x)", "100%", "done_ok", "*", "^", #"""#, "'; DROP TABLE content_items; --"] {
            _ = try await f.find(q)
        }
        #expect(try await f.ids(#""hello""#) == [hit])
        #expect(try await f.ids("100%") == [hit])
        #expect(try await f.ids("done_ok") == [hit])
    }

    @Test func limitTotalAndHasMore() async throws {
        let f = try Fixture()
        for i in 0..<5 { try await f.add("match \(i)") }
        let page = try await f.find("match") { $0.limit = 2 }
        #expect(page.items.count == 2)
        #expect(page.total == 5)
        #expect(page.hasMore)
        let all = try await f.find("match") { $0.limit = nil }
        #expect(all.items.count == 5)
        #expect(all.hasMore == false)
        await #expect(throws: SearchError.invalidLimit(0)) { try await f.find("match") { $0.limit = 0 } }
    }

    @Test func previewIsSizeCapped() async throws {
        let f = try Fixture()
        try await f.add(String(repeating: "x", count: 10_000))
        let item = try #require(try await f.find(nil).items.first)
        #expect(item.preview?.count == MuninnLimits.previewCharacters)
        #expect(item.byteSize == 10_000)
    }

    @Test func cancelledSearchThrowsCancellation() async throws {
        let f = try Fixture()
        try await f.add("anything")
        // Cancel from inside the task so the search can't finish first.
        let task = Task { () async throws -> ItemPage in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.find("anything")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite("SearchService: filters and policy")
struct FilterTests {
    @Test func appFilterMatchesBundleIDOrName() async throws {
        let f = try Fixture()
        let safari = try await f.add("from safari", app: "Safari", bundleID: "com.apple.Safari")
        try await f.add("from terminal", app: "Terminal")
        #expect(try await f.ids(nil) { $0.app = "com.apple.safari" } == [safari])
        #expect(try await f.ids(nil) { $0.app = "safari" } == [safari])
        #expect(try await f.ids("from") { $0.app = "Safari" } == [safari])
    }

    @Test func typeFilterUsesKindsAndUTIConformance() async throws {
        let f = try Fixture()
        let image = try await f.addImage()
        let note = try await f.add("note")
        #expect(try await f.ids(nil) { $0.type = "image" } == [image])
        #expect(try await f.ids(nil) { $0.type = "public.png" } == [image])
        #expect(try await f.ids(nil) { $0.type = "text" } == [note])
        #expect(try await f.ids(nil) { $0.type = "pdf" } == [])
    }

    @Test func dateRangeMatchesAnyCapture() async throws {
        let f = try Fixture()
        let old = try await f.add("recopied", ago: 10 * 24 * 3600)
        try await f.add("recopied", ago: 60) // same item, captured again now
        let middle = try await f.add("middle", ago: 5 * 24 * 3600)
        let range = try await f.ids(nil) {
            $0.since = f.now.addingTimeInterval(-11 * 24 * 3600)
            $0.until = f.now.addingTimeInterval(-4 * 24 * 3600)
        }
        #expect(Set(range) == [old, middle])
    }

    @Test func pinnedFilterAndBoost() async throws {
        let f = try Fixture()
        let pinned = try await f.add("report draft", ago: 3 * 24 * 3600)
        let recent = try await f.add("report draft ", ago: 3 * 24 * 3600 - 1)
        _ = recent
        try await f.writer.setPinned(pinned, true)
        #expect(try await f.ids(nil) { $0.pinned = true } == [pinned])
        #expect(try await f.ids("report draft").first == pinned)
    }

    @Test func protectedItemsAreExcludedWithoutLeakingCounts() async throws {
        let f = try Fixture()
        let secret = try await f.add("password hunter2")
        let open = try await f.add("password policy doc")
        try await f.writer.setProtected(secret, true)

        let cli = try await f.find("password")
        #expect(cli.items.map(\.id) == [open])
        #expect(cli.total == 1)
        #expect(cli.hasMore == false)

        let panel = try await f.find("password") { $0.excludeProtected = false }
        #expect(Set(panel.items.map(\.id)) == [secret, open])
    }

    @Test func deletedItemsDisappearFromSearch() async throws {
        let f = try Fixture()
        let gone = try await f.add("temporary token abc123")
        #expect(try await f.ids("abc123") == [gone])
        try await f.writer.delete(gone)
        #expect(try await f.ids("abc123") == [])
    }
}
