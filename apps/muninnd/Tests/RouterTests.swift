import Testing
import Foundation
import MuninnCore
import MuninnStore
import MuninnSearch
@testable import muninnd

// The helper's request handling against a temporary store and a scripted
// capture control. No pasteboard, socket or real data directory involved.

actor ScriptedCapture: CaptureControl {
    private(set) var isPaused = false
    private(set) var restored: [(itemID: Int64, representations: [RepresentationInput])] = []

    func pause() { isPaused = true }
    func resume() { isPaused = false }
    func state() -> (isPaused: Bool, counters: CaptureCounters) {
        var counters = CaptureCounters()
        counters.observedChanges = 3
        return (isPaused, counters)
    }
    func restore(itemID: Int64, representations: [RepresentationInput]) {
        restored.append((itemID, representations))
    }
}

final class Helper {
    let directory: URL
    let writer: StoreWriter
    let capture = ScriptedCapture()
    let router: RequestRouter

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("muninnd-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("muninn.db").path
        writer = try StoreWriter(path: path)
        let readers = try ReaderPool(path: path)
        router = RequestRouter(
            writer: writer, readers: readers, search: SearchService(pool: readers),
            capture: capture, startedAt: Date(), dataDirectory: directory.path,
            databasePath: path, memoryFootprint: { 42 })
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    func add(_ text: String, app: String? = nil) async throws -> Int64 {
        try await writer.capture(CaptureInput(
            capturedAt: Date(), source: SourceApp(bundleID: nil, name: app, confidence: .low),
            changeCount: nil, availableTypes: ["public.utf8-plain-text"],
            representations: [RepresentationInput(uti: "public.utf8-plain-text", role: .primary, payload: .text(text))]
        )).itemID
    }

    func call<P: Codable & Sendable, T: Codable & Sendable>(
        _ method: IPCMethod, _ params: P, as type: T.Type = T.self
    ) async throws -> IPCResponse<T> {
        let request = try MuninnJSON.encoder().encode(IPCRequest(method, params))
        return try MuninnJSON.decoder().decode(IPCResponse<T>.self, from: await router.handle(request))
    }

    func raw(_ json: String) async throws -> IPCResponse<NoParams> {
        try MuninnJSON.decoder().decode(IPCResponse<NoParams>.self, from: await router.handle(Data(json.utf8)))
    }
}

@Suite("muninnd request routing")
struct RouterTests {
    @Test func helloAndStatus() async throws {
        let h = try Helper()
        try await h.add("one")
        #expect(try await h.call(.hello, NoParams(), as: HelloInfo.self).get().protocolVersion == MuninnProtocol.version)
        let status = try await h.call(.status, NoParams(), as: StatusInfo.self).get()
        #expect(status.itemCount == 1)
        #expect(status.isPaused == false)
        #expect(status.counters.observedChanges == 3)
        #expect(status.isDevBuild)
        #expect(status.helperVersion == MuninnProtocol.productVersion)
        #expect(status.lastCaptureAt != nil)
        #expect(status.databaseBytes > 0)
        #expect(status.helperMemoryBytes == 42)
    }

    @Test func listAndSearchGoThroughSearchService() async throws {
        let h = try Helper()
        let a = try await h.add("deploy notes", app: "Notes")
        let b = try await h.add("grocery list", app: "Reminders")
        let list = try await h.call(.list, SearchRequest(query: "ignored for list"), as: ItemPage.self).get()
        #expect(list.items.map(\.id) == [b, a])

        let search = try await h.call(.search, SearchRequest(query: "deploy"), as: ItemPage.self).get()
        #expect(search.items.map(\.id) == [a])
        let filtered = try await h.call(.search, SearchRequest(app: "Reminders"), as: ItemPage.self).get()
        #expect(filtered.items.map(\.id) == [b])
    }

    @Test func protectedItemsAreHiddenWhateverTheRequestSays() async throws {
        let h = try Helper()
        let secret = try await h.add("secret")
        try await h.writer.setProtected(secret, true)
        let list = try await h.call(.list, SearchRequest(excludeProtected: false), as: ItemPage.self).get()
        #expect(list.items.isEmpty)
        #expect(list.total == 0)
        for method in [IPCMethod.get, .history, .copy] {
            let response = try await h.call(method, ItemIDParams(id: secret), as: NoParams.self)
            #expect(response.error?.code == .notFound, "\(method)")
        }
        #expect(await h.capture.restored.isEmpty)
    }

    @Test func getAndHistory() async throws {
        let h = try Helper()
        let id = try await h.add("full text here")
        try await h.add("full text here")
        let detail = try await h.call(.get, ItemIDParams(id: id), as: ItemDetail.self).get()
        #expect(detail.text == "full text here")
        #expect(detail.summary.captureCount == 2)
        let history = try await h.call(.history, ItemIDParams(id: id), as: HistoryInfo.self).get()
        #expect(history.events.count == 2)
        #expect(try await h.call(.get, ItemIDParams(id: 999), as: ItemDetail.self).error?.code == .notFound)
    }

    @Test func copyRestoresStoredRepresentations() async throws {
        let h = try Helper()
        let id = try await h.add("copy me")
        #expect(try await h.call(.copy, ItemIDParams(id: id), as: ItemRef.self).get() == ItemRef(id: id))
        let restored = await h.capture.restored
        #expect(restored.count == 1)
        #expect(restored.first?.itemID == id)
        #expect(restored.first?.representations.first?.payload == .text("copy me"))
    }

    @Test func copyOfAnItemWithNoStoredContentIsUnsupported() async throws {
        let h = try Helper()
        let id = try await h.writer.capture(CaptureInput(
            capturedAt: Date(), source: .unknown, changeCount: nil, availableTypes: ["public.png"],
            representations: [RepresentationInput(uti: "public.png", role: .primary, payload: .omitted(.size))]
        )).itemID
        #expect(try await h.call(.copy, ItemIDParams(id: id), as: ItemRef.self).error?.code == .unsupported)
    }

    @Test func pinUnpinDeleteAndPause() async throws {
        let h = try Helper()
        let id = try await h.add("x")
        _ = try await h.call(.pin, ItemIDParams(id: id), as: ItemRef.self).get()
        #expect(try await h.call(.search, SearchRequest(pinned: true), as: ItemPage.self).get().items.map(\.id) == [id])
        _ = try await h.call(.unpin, ItemIDParams(id: id), as: ItemRef.self).get()
        #expect(try await h.call(.search, SearchRequest(pinned: true), as: ItemPage.self).get().items.isEmpty)

        #expect(try await h.call(.pause, NoParams(), as: PausedState.self).get().isPaused)
        #expect(try await h.call(.status, NoParams(), as: StatusInfo.self).get().isPaused)
        #expect(try await h.call(.resume, NoParams(), as: PausedState.self).get().isPaused == false)

        _ = try await h.call(.delete, ItemIDParams(id: id), as: ItemRef.self).get()
        #expect(try await h.call(.delete, ItemIDParams(id: id), as: ItemRef.self).error?.code == .notFound)
        #expect(try await h.call(.pin, ItemIDParams(id: id), as: ItemRef.self).error?.code == .notFound)
    }

    @Test func badRequestsGetStableCodes() async throws {
        let h = try Helper()
        #expect(try await h.raw("not json").error?.code == .invalidRequest)
        #expect(try await h.raw(#"{"version":2,"method":"teleport","params":{}}"#).error?.code == .unsupported)
        #expect(try await h.raw(#"{"version":2,"method":"get","params":{"id":"seven"}}"#).error?.code == .invalidRequest)
        #expect(try await h.call(.search, SearchRequest(limit: 0), as: ItemPage.self).error?.code == .invalidRequest)
    }

    @Test func otherProtocolVersionsAreIncompatible() async throws {
        let h = try Helper()
        let missing = try await h.raw(#"{"method":"status","params":{}}"#)
        #expect(missing.error?.code == .incompatible)
        let newer = try await h.raw(#"{"version":99,"method":"status","params":{}}"#)
        #expect(newer.error?.code == .incompatible)
        #expect(newer.error?.message.contains("99") == true)
        // The version is checked before the method: an unknown method from another version is still incompatible.
        #expect(try await h.raw(#"{"version":1,"method":"teleport","params":{}}"#).error?.code == .incompatible)
    }

    @Test func payloadServesBytesAndStableCodes() async throws {
        let h = try Helper()
        let id = try await h.add("paste me")
        let chunk = try await h.call(.payload, PayloadRequest(id: id), as: PayloadChunk.self).get()
        #expect(chunk.data == Data("paste me".utf8))
        #expect(chunk.chunkCount == 1)
        #expect(chunk.uti == "public.utf8-plain-text")

        let pinned = try await h.call(.payload, PayloadRequest(id: id, representationID: chunk.representationID), as: PayloadChunk.self).get()
        #expect(pinned == chunk)

        #expect(try await h.call(.payload, PayloadRequest(id: id, as: "image"), as: PayloadChunk.self).error?.code == .notFound)
        #expect(try await h.call(.payload, PayloadRequest(id: id, chunk: 1), as: PayloadChunk.self).error?.code == .invalidRequest)
        #expect(try await h.call(.payload, PayloadRequest(id: 999), as: PayloadChunk.self).error?.code == .notFound)

        let omitted = try await h.writer.capture(CaptureInput(
            capturedAt: Date(), source: .unknown, changeCount: nil, availableTypes: ["public.png"],
            representations: [RepresentationInput(uti: "public.png", role: .primary, payload: .omitted(.size))]
        )).itemID
        let refused = try await h.call(.payload, PayloadRequest(id: omitted), as: PayloadChunk.self)
        #expect(refused.error?.code == .unsupported)
        #expect(refused.error?.message.contains("size") == true)
    }

    @Test func payloadOfAProtectedItemIsNotFound() async throws {
        let h = try Helper()
        let secret = try await h.add("secret")
        try await h.writer.setProtected(secret, true)
        let response = try await h.call(.payload, PayloadRequest(id: secret), as: PayloadChunk.self)
        #expect(response.error?.code == .notFound)
        #expect(response.error?.message.contains("secret") == false)
    }

    @Test func diagnosticsReportStoreAndCapture() async throws {
        let h = try Helper()
        try await h.add("one")
        let d = try await h.call(.diagnostics, NoParams(), as: DiagnosticsInfo.self).get()
        #expect(d.protocolVersion == MuninnProtocol.version)
        #expect(d.databaseCheck == ["ok"])
        #expect(d.searchIndexError == nil)
        #expect(d.staleIndexItems == 0)
        #expect(d.lastCaptureAt != nil)
        #expect(d.isPaused == false)
        #expect(d.counters.observedChanges == 3)
        #expect(d.databaseBytes > 0)
        #expect(d.helperMemoryBytes == 42)
    }
}
