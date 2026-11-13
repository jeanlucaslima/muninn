import Testing
import Foundation
import MuninnCore
@testable import MuninnStore

// `paste` payloads and `doctor` diagnostics, against temporary databases.

/// Reads every chunk the way the CLI does: the first picks, the rest pin.
func readAll(_ reader: StoreReader, id: Int64, selector: String? = nil, textChunkBytes: Int) async throws -> (PayloadChunk, Data) {
    let first = try await reader.read { db in
        try ItemQueries.payload(db, id: id, selector: selector, representationID: nil, chunk: 0, textChunkBytes: textChunkBytes)
    }
    guard case .chunk(let head) = first else {
        Issue.record("expected a chunk, got \(String(describing: first))")
        throw CancellationError()
    }
    var data = head.data
    for n in 1..<max(1, head.chunkCount) {
        let next = try await reader.read { db in
            try ItemQueries.payload(db, id: id, selector: nil, representationID: head.representationID, chunk: n,
                                    textChunkBytes: textChunkBytes)
        }
        guard case .chunk(let chunk) = next else {
            Issue.record("chunk \(n): \(String(describing: next))")
            throw CancellationError()
        }
        #expect(chunk.representationID == head.representationID)
        data.append(chunk.data)
    }
    return (head, data)
}

@Suite("v2 store: payloads")
struct PayloadTests {
    @Test func textIsSlicedByBytesAndReassemblesExactly() async throws {
        let tmp = try TempDB()
        let store = try StoreWriter(path: tmp.path)
        // Multi-byte characters land on chunk boundaries; bytes must still round-trip.
        let value = String(repeating: "naïve 🐦‍⬛ raven\r\n", count: 50)
        let id = try await store.capture(text(value)).itemID
        let reader = try StoreReader(path: tmp.path)

        let (head, data) = try await readAll(reader, id: id, textChunkBytes: 7)
        #expect(data == Data(value.utf8))
        #expect(head.byteSize == Int64(value.utf8.count))
        #expect(head.chunkCount == (value.utf8.count + 6) / 7)
        #expect(head.uti == plainUTI)
    }

    @Test func emptyTextIsOneEmptyChunk() async throws {
        let tmp = try TempDB()
        let id = try await StoreWriter(path: tmp.path).capture(text("")).itemID
        let (head, data) = try await readAll(try StoreReader(path: tmp.path), id: id, textChunkBytes: 4)
        #expect(head.chunkCount == 1)
        #expect(data.isEmpty)
    }

    @Test func assetsGoOutOneStoredChunkAtATime() async throws {
        let tmp = try TempDB()
        let store = try StoreWriter(path: tmp.path, chunkSize: 1000)
        let bytes = Data((0..<2500).map { UInt8($0 % 251) })
        let id = try await store.capture(capture([RepresentationInput(uti: pngUTI, role: .primary, payload: .data(bytes))])).itemID

        let (head, data) = try await readAll(try StoreReader(path: tmp.path), id: id, textChunkBytes: 7)
        #expect(head.chunkCount == 3)
        #expect(head.data.count == 1000)
        #expect(data == bytes)
    }

    @Test func selectorPicksByKindOrUTIAndDefaultsToPrimary() async throws {
        let tmp = try TempDB()
        let store = try StoreWriter(path: tmp.path)
        let id = try await store.capture(capture([
            RepresentationInput(uti: htmlUTI, role: .primary, payload: .text("<b>hi</b>")),
            RepresentationInput(uti: plainUTI, role: .alternate, payload: .text("hi")),
        ])).itemID
        let reader = try StoreReader(path: tmp.path)

        #expect(try await readAll(reader, id: id, textChunkBytes: 64).1 == Data("<b>hi</b>".utf8))
        #expect(try await readAll(reader, id: id, selector: "text", textChunkBytes: 64).1 == Data("hi".utf8))
        #expect(try await readAll(reader, id: id, selector: plainUTI, textChunkBytes: 64).1 == Data("hi".utf8))
        #expect(try await readAll(reader, id: id, selector: "html", textChunkBytes: 64).1 == Data("<b>hi</b>".utf8))

        let missing = try await reader.read { db in
            try ItemQueries.payload(db, id: id, selector: "image", representationID: nil, chunk: 0)
        }
        #expect(missing == .noSuchRepresentation)
    }

    @Test func fileReferencesPasteAsTheirURL() async throws {
        let tmp = try TempDB()
        let url = "file:///Users/someone/report.pdf"
        let id = try await StoreWriter(path: tmp.path).capture(capture([
            RepresentationInput(uti: "public.file-url", role: .primary, payload: .fileURL(url, fileSize: 10, modifiedAt: nil)),
        ])).itemID
        #expect(try await readAll(try StoreReader(path: tmp.path), id: id, textChunkBytes: 8).1 == Data(url.utf8))
    }

    @Test func omittedStoredMatchIsPreferredAndAllOmittedIsReported() async throws {
        let tmp = try TempDB()
        let store = try StoreWriter(path: tmp.path)
        let id = try await store.capture(capture([
            RepresentationInput(uti: "public.tiff", role: .primary, payload: .omitted(.size)),
            RepresentationInput(uti: pngUTI, role: .alternate, payload: .data(Data([1, 2, 3]))),
        ])).itemID
        let reader = try StoreReader(path: tmp.path)

        // The primary is omitted: no default, but `--as image` finds the stored PNG.
        let primary = try await reader.read { db in
            try ItemQueries.payload(db, id: id, selector: nil, representationID: nil, chunk: 0)
        }
        #expect(primary == .omitted(.size))
        let (head, data) = try await readAll(reader, id: id, selector: "image", textChunkBytes: 8)
        #expect(head.uti == pngUTI)
        #expect(data == Data([1, 2, 3]))
    }

    @Test func missingItemOutOfRangeChunkAndForeignRepresentation() async throws {
        let tmp = try TempDB()
        let store = try StoreWriter(path: tmp.path)
        let a = try await store.capture(text("a")).itemID
        let b = try await store.capture(text("b")).itemID
        let reader = try StoreReader(path: tmp.path)
        let bRep = try await reader.read { db in try #require(try ItemQueries.detail(db, id: b)).representations[0].id }

        let results = try await reader.read { db in
            [
                try ItemQueries.payload(db, id: 999, selector: nil, representationID: nil, chunk: 0),
                try ItemQueries.payload(db, id: a, selector: nil, representationID: nil, chunk: 1),
                try ItemQueries.payload(db, id: a, selector: nil, representationID: nil, chunk: -1),
                // A representation id from another item doesn't leak its bytes.
                try ItemQueries.payload(db, id: a, selector: nil, representationID: bRep, chunk: 0),
            ]
        }
        #expect(results == [nil, .chunkOutOfRange, .chunkOutOfRange, .noSuchRepresentation])
    }
}

@Suite("v2 store: diagnostics")
struct DiagnosticsTests {
    @Test func soundDatabaseReportsOk() async throws {
        let tmp = try TempDB()
        let store = try StoreWriter(path: tmp.path)
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.capture(text("one", at: when))
        let reader = try StoreReader(path: tmp.path)

        let (check, stale, last) = try await reader.read { db in
            (try ItemQueries.quickCheck(db), try ItemQueries.staleIndexCount(db), try ItemQueries.lastCaptureAt(db))
        }
        #expect(check == ["ok"])
        #expect(stale == 0)
        #expect(last == when)
        #expect(await store.searchIndexError() == nil)
    }

    @Test func staleAndEmptyAreReported() async throws {
        let tmp = try TempDB()
        let store = try StoreWriter(path: tmp.path)
        let reader = try StoreReader(path: tmp.path)
        #expect(try await reader.read { try ItemQueries.lastCaptureAt($0) } == nil)

        let id = try await store.capture(text("one")).itemID
        try tmp.raw().run("UPDATE content_items SET indexed_version = NULL WHERE id = ?", [.int(id)])
        #expect(try await reader.read { try ItemQueries.staleIndexCount($0) } == 1)
    }
}
