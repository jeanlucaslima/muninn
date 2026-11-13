import Foundation
import MuninnCore
import MuninnStore
import MuninnSearch

/// What request handling needs from capture. The system version wraps the
/// pasteboard monitor; tests use a scripted one (§4.1 test seams).
protocol CaptureControl: Sendable {
    func pause() async
    func resume() async
    func state() async -> (isPaused: Bool, counters: CaptureCounters)
    /// Puts an item's representations back on the pasteboard, marked as Muninn's own write.
    func restore(itemID: Int64, representations: [RepresentationInput]) async
}

/// Decodes one IPC request, runs it against the store and search, and
/// encodes the response. Every failure becomes a stable error code (§4.6).
///
/// Not yet: caller identity and the access policy (§4.12). Until then the
/// helper serves the CLI and the app alike and excludes protected items for
/// everyone, whatever the request says.
struct RequestRouter: Sendable {
    let writer: StoreWriter
    let readers: ReaderPool
    let search: SearchService
    let capture: any CaptureControl
    let startedAt: Date
    let dataDirectory: String
    let databasePath: String
    /// The helper's physical memory footprint, for `doctor`; nil if unknown.
    let memoryFootprint: @Sendable () -> Int64?

    func handle(_ data: Data) async -> Data {
        do {
            let header = try MuninnJSON.decoder().decode(IPCRequestHeader.self, from: data)
            guard header.version == MuninnProtocol.version else {
                let theirs = header.version.map(String.init) ?? "none"
                throw IPCFailure(.incompatible,
                    "protocol version \(theirs) isn't supported; this helper speaks version \(MuninnProtocol.version)")
            }
            guard let method = IPCMethod(rawValue: header.method) else {
                throw IPCFailure(.unsupported, "unknown method: \(header.method)")
            }
            return try await dispatch(method, data)
        } catch let failure as IPCFailure {
            return encode(IPCResponse<NoParams>.failure(failure))
        } catch is DecodingError {
            return encode(IPCResponse<NoParams>.failure(IPCFailure(.invalidRequest, "malformed request")))
        } catch let error as SearchError {
            return encode(IPCResponse<NoParams>.failure(IPCFailure(.invalidRequest, "\(error)")))
        } catch {
            // Error descriptions here come from SQLite and the store; they never contain clipboard content.
            return encode(IPCResponse<NoParams>.failure(IPCFailure(.internal, "\(error)")))
        }
    }

    private func dispatch(_ method: IPCMethod, _ data: Data) async throws -> Data {
        switch method {
        case .hello:
            return ok(HelloInfo(protocolVersion: MuninnProtocol.version))

        case .status:
            let state = await capture.state()
            let count = try await readers.read { try ItemQueries.itemCount($0) }
            return ok(StatusInfo(
                protocolVersion: MuninnProtocol.version,
                itemCount: count,
                isPaused: state.isPaused,
                uptimeSeconds: Int(Date().timeIntervalSince(startedAt)),
                dataDirectory: dataDirectory,
                isDevBuild: MuninnPaths.isDevBuild,
                counters: state.counters
            ))

        case .diagnostics:
            let state = await capture.state()
            let (check, stale, lastCapture) = try await readers.read { db in
                (try ItemQueries.quickCheck(db), try ItemQueries.staleIndexCount(db), try ItemQueries.lastCaptureAt(db))
            }
            let indexError = await writer.searchIndexError()
            let fm = FileManager.default
            let databaseBytes = [databasePath, databasePath + "-wal"].reduce(Int64(0)) { sum, path in
                sum + ((try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0)
            }
            let free = (try? URL(fileURLWithPath: dataDirectory)
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
            return ok(DiagnosticsInfo(
                protocolVersion: MuninnProtocol.version,
                isDevBuild: MuninnPaths.isDevBuild,
                databaseCheck: check,
                searchIndexError: indexError,
                staleIndexItems: stale,
                isPaused: state.isPaused,
                lastCaptureAt: lastCapture,
                counters: state.counters,
                databaseBytes: databaseBytes,
                freeDiskBytes: free,
                helperMemoryBytes: memoryFootprint()
            ))

        case .list:
            var request = try params(SearchRequest.self, data)
            request.query = nil
            request.excludeProtected = true
            return ok(try await search.search(request))

        case .search:
            var request = try params(SearchRequest.self, data)
            request.excludeProtected = true
            return ok(try await search.search(request))

        case .get:
            let id = try params(ItemIDParams.self, data).id
            guard let detail = try await readers.read({ try ItemQueries.detail($0, id: id) }),
                  !detail.summary.isProtected else {
                throw notFound(id)
            }
            return ok(detail)

        case .history:
            let id = try params(ItemIDParams.self, data).id
            guard let events = try await readers.read({ db -> [CaptureEventInfo]? in
                guard let detail = try ItemQueries.detail(db, id: id), !detail.summary.isProtected else { return nil }
                return try ItemQueries.history(db, id: id)
            }) else {
                throw notFound(id)
            }
            return ok(HistoryInfo(id: id, events: events))

        case .payload:
            let request = try params(PayloadRequest.self, data)
            let id = request.id
            guard let result = try await readers.read({ db -> PayloadResult? in
                guard let detail = try ItemQueries.detail(db, id: id), !detail.summary.isProtected else { return nil }
                return try ItemQueries.payload(db, id: id, selector: request.as,
                                               representationID: request.representationID, chunk: request.chunk)
            }) else {
                throw notFound(id)
            }
            switch result {
            case .chunk(let chunk):
                return ok(chunk)
            case .noSuchRepresentation:
                let what = request.as.map { "\($0) representation" } ?? "primary representation"
                throw IPCFailure(.notFound, "item \(id) has no \(what)")
            case .omitted(let reason):
                throw IPCFailure(.unsupported, "item \(id)'s representation wasn't stored (omitted: \(reason.rawValue))")
            case .chunkOutOfRange:
                throw IPCFailure(.invalidRequest, "chunk \(request.chunk) is out of range")
            }

        case .copy:
            let id = try params(ItemIDParams.self, data).id
            guard let reps = try await readers.read({ db -> [RepresentationInput]? in
                guard let detail = try ItemQueries.detail(db, id: id), !detail.summary.isProtected else { return nil }
                return try ItemQueries.restorable(db, id: id)
            }) else {
                throw notFound(id)
            }
            guard !reps.isEmpty else {
                throw IPCFailure(.unsupported, "item \(id) has no stored content to copy")
            }
            await capture.restore(itemID: id, representations: reps)
            return ok(ItemRef(id: id))

        case .pause:
            await capture.pause()
            return ok(PausedState(isPaused: true))

        case .resume:
            await capture.resume()
            return ok(PausedState(isPaused: false))

        case .pin, .unpin:
            let id = try params(ItemIDParams.self, data).id
            guard try await writer.setPinned(id, method == .pin) else { throw notFound(id) }
            return ok(ItemRef(id: id))

        case .delete:
            let id = try params(ItemIDParams.self, data).id
            guard try await writer.delete(id) else { throw notFound(id) }
            return ok(ItemRef(id: id))
        }
    }

    private func params<P: Codable & Sendable>(_ type: P.Type, _ data: Data) throws -> P {
        do {
            return try MuninnJSON.decoder().decode(IPCRequest<P>.self, from: data).params
        } catch {
            throw IPCFailure(.invalidRequest, "invalid params")
        }
    }

    private func notFound(_ id: Int64) -> IPCFailure {
        IPCFailure(.notFound, "item \(id) not found")
    }

    private func ok<T: Codable & Sendable>(_ value: T) -> Data {
        encode(IPCResponse.success(value))
    }

    private func encode<T: Codable & Sendable>(_ response: IPCResponse<T>) -> Data {
        (try? MuninnJSON.encoder().encode(response))
            ?? Data(#"{"ok":false,"error":{"code":"internal","message":"encoding failed"}}"#.utf8)
    }
}
