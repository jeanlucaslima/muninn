import Foundation
import MuninnCore
import MuninnIPC

/// The panel's connection to the helper. Requests are short local-socket
/// round trips; the actor keeps them off the main actor.
actor DaemonClient {
    private let ipc = IPCClient(socketPath: MuninnPaths.socketPath)

    func list(limit: Int = 50) throws -> ItemPage {
        try call(.list, SearchRequest(limit: limit), as: ItemPage.self)
    }

    func search(query: String, limit: Int = 50) throws -> ItemPage {
        try call(.search, SearchRequest(query: query, limit: limit), as: ItemPage.self)
    }

    func copy(id: Int64) throws {
        _ = try call(.copy, ItemIDParams(id: id), as: ItemRef.self)
    }

    func delete(id: Int64) throws {
        _ = try call(.delete, ItemIDParams(id: id), as: ItemRef.self)
    }

    func setPinned(id: Int64, _ pinned: Bool) throws {
        _ = try call(pinned ? .pin : .unpin, ItemIDParams(id: id), as: ItemRef.self)
    }

    func setPaused(_ paused: Bool) throws -> Bool {
        try call(paused ? .pause : .resume, NoParams(), as: PausedState.self).isPaused
    }

    func status() throws -> StatusInfo {
        try call(.status, NoParams(), as: StatusInfo.self)
    }

    private func call<P: Codable & Sendable, T: Codable & Sendable>(_ method: IPCMethod, _ params: P, as type: T.Type) throws -> T {
        try Task.checkCancellation()
        return try ipc.call(method, params, as: T.self).get()
    }
}
