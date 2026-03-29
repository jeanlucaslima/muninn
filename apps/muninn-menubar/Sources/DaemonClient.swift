import Foundation
import MuninnCore
import MuninnIPC

actor DaemonClient {
    private let ipc: IPCClient
    private let queue = DispatchQueue(label: "muninn.ipc", qos: .userInitiated)

    init() {
        self.ipc = IPCClient(socketPath: MuninnPaths.socketPath)
    }

    func list(limit: Int = 50, offset: Int = 0) async throws -> ListResponseData {
        try await call(
            IPCRequest(method: "list", params: .list(.init(limit: limit, offset: offset))),
            as: IPCResponse<ListResponseData>.self
        )
    }

    func search(query: String, limit: Int = 50) async throws -> SearchResponseData {
        try await call(
            IPCRequest(method: "search", params: .search(.init(query: query, limit: limit))),
            as: IPCResponse<SearchResponseData>.self
        )
    }

    func copy(id: Int64) async throws -> ClipboardEntry {
        try await call(
            IPCRequest(method: "copy", params: .copy(.init(id: id))),
            as: IPCResponse<ClipboardEntry>.self
        )
    }

    func delete(id: Int64) async throws {
        let _: [String: Int64] = try await call(
            IPCRequest(method: "delete", params: .delete(.init(id: id))),
            as: IPCResponse<[String: Int64]>.self
        )
    }

    func pin(id: Int64) async throws -> ClipboardEntry {
        try await call(
            IPCRequest(method: "pin", params: .pin(.init(id: id))),
            as: IPCResponse<ClipboardEntry>.self
        )
    }

    func unpin(id: Int64) async throws -> ClipboardEntry {
        try await call(
            IPCRequest(method: "unpin", params: .unpin(.init(id: id))),
            as: IPCResponse<ClipboardEntry>.self
        )
    }

    func pause() async throws -> Bool {
        let result: [String: Bool] = try await call(
            IPCRequest(method: "pause", params: .pause),
            as: IPCResponse<[String: Bool]>.self
        )
        return result["paused"] ?? true
    }

    func resume() async throws -> Bool {
        let result: [String: Bool] = try await call(
            IPCRequest(method: "resume", params: .resume),
            as: IPCResponse<[String: Bool]>.self
        )
        return result["paused"] ?? false
    }

    func status() async throws -> StatusResponseData {
        try await call(
            IPCRequest(method: "status", params: .status),
            as: IPCResponse<StatusResponseData>.self
        )
    }

    private func call<T: Codable & Sendable>(
        _ request: IPCRequest,
        as type: IPCResponse<T>.Type
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [ipc] in
                do {
                    let data = try ipc.send(request)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let response = try decoder.decode(IPCResponse<T>.self, from: data)
                    if response.ok, let data = response.data {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: DaemonError.serverError(
                            response.error ?? "unknown error"
                        ))
                    }
                } catch let error as DaemonError {
                    continuation.resume(throwing: error)
                } catch {
                    continuation.resume(throwing: DaemonError.connectionFailed(error.localizedDescription))
                }
            }
        }
    }
}

enum DaemonError: Error {
    case connectionFailed(String)
    case serverError(String)
}
