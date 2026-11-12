import Testing
import Foundation
import MuninnCore
@testable import MuninnStore

// v2 store: schema, identity, assets, deletion, index step.
// Every test uses its own temporary database; nothing touches real user data.

final class TempDB {
    let directory: URL
    var path: String { directory.appendingPathComponent("muninn.db").path }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muninn-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A raw connection for assertions on tables the public API doesn't expose.
    func raw() throws -> Database {
        try Database(path: path, readOnly: false)
    }

    func count(_ sql: String, _ args: [SQLValue] = []) throws -> Int {
        Int(try raw().queryOne(sql, args) { $0.int(0) } ?? -1)
    }
}

let plainUTI = "public.utf8-plain-text"
let htmlUTI = "public.html"
let pngUTI = "public.png"
let rtfUTI = "public.rtf"

func capture(
    _ reps: [RepresentationInput],
    at date: Date = Date(),
    app: String? = nil,
    bundleID: String? = nil
) -> CaptureInput {
    CaptureInput(
        capturedAt: date,
        source: SourceApp(bundleID: bundleID, name: app, confidence: bundleID == nil ? .low : .high),
        changeCount: nil,
        availableTypes: reps.map(\.uti),
        representations: reps
    )
}

func text(_ s: String, at date: Date = Date(), app: String? = nil, bundleID: String? = nil) -> CaptureInput {
    capture([RepresentationInput(uti: plainUTI, role: .primary, payload: .text(s))], at: date, app: app, bundleID: bundleID)
}

@Suite("v2 store: schema")
struct SchemaTests {
    @Test func migrationsAreRecordedOnce() async throws {
        let tmp = try TempDB()
        _ = try StoreWriter(path: tmp.path)
        _ = try StoreWriter(path: tmp.path)
        #expect(try tmp.count("SELECT COUNT(*) FROM schema_migrations") == Schema.migrations.count)
    }

    @Test func checksumMismatchIsAStartupError() async throws {
        let tmp = try TempDB()
        _ = try StoreWriter(path: tmp.path)
        try tmp.raw().run("UPDATE schema_migrations SET checksum = 'tampered' WHERE version = 1")
        #expect(throws: StoreError.migrationChecksumMismatch(version: 1)) {
            _ = try StoreWriter(path: tmp.path)
        }
    }

    @Test func unknownNewerMigrationIsAStartupError() async throws {
        let tmp = try TempDB()
        _ = try StoreWriter(path: tmp.path)
        try tmp.raw().run("INSERT INTO schema_migrations VALUES (999, 'future', 0, 'x')")
        #expect(throws: StoreError.unknownMigration(version: 999)) {
            _ = try StoreWriter(path: tmp.path)
        }
    }
}

@Suite("v2 store: identity")
struct IdentityTests {
    @Test func sameTextAgainIsOneItemWithSeveralEvents() async throws {
        let tmp = try TempDB()
        let store = try StoreWriter(path: tmp.path)
        let a1 = try await store.capture(text("alpha"))
        let b = try await store.capture(text("beta"))
        let a2 = try await store.capture(text("alpha"))

        guard case .created = a1, case .deduplicated = a2 else {
            Issue.record("expected created then deduplicated, got \(a1), \(a2)")
            return
        }
        #expect(a1.itemID == a2.itemID)
        #expect(b.itemID != a1.itemID)
        #expect(try tmp.count("SELECT COUNT(*) FROM content_items") == 2)
        #expect(try tmp.count("SELECT COUNT(*) FROM capture_events") == 3)
        #expect(try tmp.count("SELECT capture_count FROM content_items WHERE id = ?", [.int(a1.itemID)]) == 2)
    }

    @Test func browserAndTerminalCopiesOfTheSameTextMerge() async throws {
        let tmp = try TempDB()
        let store = try StoreWriter(path: tmp.path)
        let terminal = try await store.capture(text("hello"))
        let browser = try await store.capture(capture([
            RepresentationInput(uti: plainUTI, role: .primary, payload: .text("hello")),
            RepresentationInput(uti: htmlUTI, role: .alternate, payload: .text("<b>hello</b>")),
        ]))
        #expect(terminal.itemID == browser.itemID)
        // The later capture added the HTML representation the item didn't have.
        let utis = try tmp.raw().query(
            "SELECT uti, role FROM representations WHERE content_item_id = ? ORDER BY id",
            [.int(terminal.itemID)]) { "\($0.text(0)!):\($0.text(1)!)" }
        #expect(utis == ["\(plainUTI):primary", "\(htmlUTI):alternate"])
    }

    @Test func lineEndingsAndUnicodeFormsAreNormalizedForIdentity() async throws {
        let tmp = try TempDB()
        let store = try StoreWriter(path: tmp.path)
        let crlf = try await store.capture(text("a\r\nb"))
        let lf = try await store.capture(text("a\nb"))
        let decomposed = try await store.capture(text("Ac\u{0327}a\u{0303}o"))
        let composed = try await store.capture(text("Ação"))
        #expect(crlf.itemID == lf.itemID)
        #expect(decomposed.itemID == composed.itemID)
    }

    @Test func sameImageBytesAreOneItem() async throws {
        let tmp = try TempDB()
        let store = try StoreWriter(path: tmp.path)
        let png = Data((0..<500).map { UInt8($0 % 251) })
        let first = try await store.capture(capture([RepresentationInput(uti: pngUTI, role: .primary, payload: .data(png))]))
        let second = try await store.capture(capture([RepresentationInput(uti: pngUTI, role: .primary, payload: .data(png))]))
        #expect(first.itemID == second.itemID)
        #expect(try tmp.count("SELECT COUNT(*) FROM assets") == 1)
        #expect(try tmp.count("SELECT primary_kind = 'image' FROM content_items") == 1)
    }

    @Test func omittedPrimaryIsNeverDeduplicated() async throws {
        let tmp = try TempDB()
        let store = try StoreWriter(path: tmp.path)
        let omitted = capture([RepresentationInput(uti: pngUTI, role: .primary, payload: .omitted(.size))])
        let first = try await store.capture(omitted)
        let second = try await store.capture(omitted)
        #expect(first.itemID != second.itemID)
        #expect(try tmp.count("SELECT COUNT(*) FROM content_items WHERE content_hash IS NULL") == 2)
    }

    @Test func captureNeedsExactlyOnePrimary() async throws {
        let tmp = try TempDB()
        let store = try StoreWriter(path: tmp.path)
        let none = capture([RepresentationInput(uti: plainUTI, role: .alternate, payload: .text("x"))])
        await #expect(throws: StoreError.self) { try await store.capture(none) }
        #expect(try tmp.count("SELECT COUNT(*) FROM capture_events") == 0)
    }
}

@Suite("v2 store: assets and deletion")
struct AssetTests {
    @Test func assetsAreChunkedAndReadBackInOrder() async throws {
        let tmp = try TempDB()
        let store = try StoreWriter(path: tmp.path, chunkSize: 1000)
        let bytes = Data((0..<2500).map { UInt8($0 % 256) })
        let outcome = try await store.capture(capture([RepresentationInput(uti: pngUTI, role: .primary, payload: .data(bytes))]))

        let reader = try StoreReader(path: tmp.path)
        let readBack = try await reader.read { db -> Data in
            let detail = try #require(try ItemQueries.detail(db, id: outcome.itemID))
            let assetID = try #require(detail.representations.first?.assetID)
            var out = Data()
            try ItemQueries.forEachChunk(db, assetID: assetID) { out.append($0) }
            return out
        }
        #expect(readBack == bytes)
        #expect(try tmp.count("SELECT COUNT(*) FROM asset_chunks") == 3)
    }

    @Test func deleteRemovesEverythingAndKeepsSharedAssets() async throws {
        let tmp = try TempDB()
        let store = try StoreWriter(path: tmp.path)
        let sharedRTF = Data("{\\rtf1 shared}".utf8)
        func rich(_ s: String) -> CaptureInput {
            capture([
                RepresentationInput(uti: rtfUTI, role: .primary, payload: .data(sharedRTF)),
                RepresentationInput(uti: plainUTI, role: .alternate, payload: .text(s)),
            ])
        }
        let one = try await store.capture(rich("one"))
        let two = try await store.capture(rich("two"))
        #expect(one.itemID != two.itemID)
        #expect(try tmp.count("SELECT COUNT(*) FROM assets") == 1)

        #expect(try await store.delete(one.itemID))
        for table in ["capture_events", "representations"] {
            #expect(try tmp.count("SELECT COUNT(*) FROM \(table) WHERE content_item_id = ?", [.int(one.itemID)]) == 0)
        }
        #expect(try tmp.count("SELECT COUNT(*) FROM assets") == 1, "still referenced by item two")
        #expect(try tmp.count("SELECT COUNT(*) FROM search_index WHERE search_index MATCH '\"one\"'") == 0)

        #expect(try await store.delete(two.itemID))
        #expect(try tmp.count("SELECT COUNT(*) FROM assets") == 0)
        #expect(try tmp.count("SELECT COUNT(*) FROM asset_chunks") == 0)
        #expect(try tmp.count("SELECT COUNT(*) FROM search_index") == 0)
        #expect(try await store.delete(two.itemID) == false)
    }
}

@Suite("v2 store: events and index")
struct EventTests {
    @Test func selfCopyRecordsOneMuninnEvent() async throws {
        let tmp = try TempDB()
        let store = try StoreWriter(path: tmp.path)
        let item = try await store.capture(text("x"))
        let eventID = try await store.recordSelfCopy(itemID: item.itemID, at: Date(), changeCount: 42)
        #expect(eventID != nil)
        #expect(try await store.recordSelfCopy(itemID: 9999, at: Date(), changeCount: nil) == nil)

        let reader = try StoreReader(path: tmp.path)
        let history = try await reader.read { try #require(try ItemQueries.history($0, id: item.itemID)) }
        #expect(history.count == 2)
        #expect(history.last?.source.confidence == .muninn)
        #expect(history.last?.changeCount == 42)
    }

    @Test func historyKeepsSourceAndAvailableTypes() async throws {
        let tmp = try TempDB()
        let store = try StoreWriter(path: tmp.path)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let item = try await store.capture(text("x", at: t0, app: "Safari", bundleID: "com.apple.Safari"))
        try await store.capture(text("x", at: t0.addingTimeInterval(60), app: "Terminal"))

        let reader = try StoreReader(path: tmp.path)
        let history = try await reader.read { try #require(try ItemQueries.history($0, id: item.itemID)) }
        #expect(history.map(\.source.name) == ["Safari", "Terminal"])
        #expect(history.map(\.source.confidence) == [.high, .low])
        #expect(history.first?.availableTypes == [plainUTI])
        #expect(history.first?.capturedAt == t0)

        let detail = try await reader.read { try #require(try ItemQueries.detail($0, id: item.itemID)) }
        #expect(detail.summary.captureCount == 2)
        #expect(detail.summary.sourceAppName == "Terminal")
        #expect(detail.summary.lastCapturedAt == t0.addingTimeInterval(60))
        #expect(detail.text == "x")
    }

    @Test func staleItemsAreReindexedOnStart() async throws {
        let tmp = try TempDB()
        do {
            let store = try StoreWriter(path: tmp.path)
            try await store.capture(text("needle in a haystack"))
        }
        let raw = try tmp.raw()
        try raw.run("DELETE FROM search_index")
        try raw.run("UPDATE content_items SET indexed_version = NULL")
        #expect(try tmp.count("SELECT COUNT(*) FROM search_index") == 0)

        _ = try StoreWriter(path: tmp.path)
        #expect(try tmp.count("SELECT COUNT(*) FROM search_index WHERE search_index MATCH '\"needle\"'") == 1)
        #expect(try tmp.count("SELECT COUNT(*) FROM content_items WHERE indexed_version IS NULL") == 0)
    }

    @Test func pinAndProtect() async throws {
        let tmp = try TempDB()
        let store = try StoreWriter(path: tmp.path)
        let item = try await store.capture(text("x"))
        #expect(try await store.setPinned(item.itemID, true))
        #expect(try await store.setProtected(item.itemID, true))
        #expect(try await store.setPinned(12345, true) == false)
        #expect(try tmp.count("SELECT is_pinned + is_protected FROM content_items") == 2)
    }

    @Test func filesPreviewNamesTheFirstFileAndCountsTheRest() async throws {
        let tmp = try TempDB()
        let store = try StoreWriter(path: tmp.path)
        let item = try await store.capture(capture([
            RepresentationInput(uti: "public.file-url", role: .primary, payload: .fileURL("file:///tmp/a.txt", fileSize: 3, modifiedAt: nil)),
            RepresentationInput(uti: "public.file-url", role: .alternate, payload: .fileURL("file:///tmp/b.txt", fileSize: 4, modifiedAt: nil)),
        ]))
        let reader = try StoreReader(path: tmp.path)
        let summary = try await reader.read { try ItemQueries.summaries($0, ids: [item.itemID]) }
        #expect(summary.first?.preview == "a.txt (+1 more)")
        #expect(summary.first?.kind == .file)
    }
}
