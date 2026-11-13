import Testing
import Foundation
import MuninnCore
@testable import MuninnIPC

func tempSocketPath() -> String {
    // sun_path is short (104 bytes), so keep this under /tmp.
    "/tmp/mn-ipc-\(UUID().uuidString.prefix(8)).sock"
}

/// An echo server: replies to `hello` and fails everything else.
func startServer(_ path: String, delay: Duration = .zero) throws -> IPCServer {
    let server = IPCServer(socketPath: path) { data in
        if delay > .zero { try? await Task.sleep(for: delay) }
        let header = try? MuninnJSON.decoder().decode(IPCRequestHeader.self, from: data)
        if header?.method == "hello" {
            return try! MuninnJSON.encoder().encode(IPCResponse.success(HelloInfo(protocolVersion: MuninnProtocol.version)))
        }
        return try! MuninnJSON.encoder().encode(IPCResponse<NoParams>.failure(IPCFailure(.unsupported, "nope")))
    }
    try server.start()
    return server
}

@Suite("IPC transport")
struct IPCTransportTests {
    @Test func roundtripDecodesData() throws {
        let path = tempSocketPath()
        let server = try startServer(path)
        defer { server.stop() }

        let response = try IPCClient(socketPath: path).call(.hello, NoParams(), as: HelloInfo.self)
        #expect(try response.get() == HelloInfo(protocolVersion: MuninnProtocol.version))
    }

    @Test func failureEnvelopeThrowsFromGet() throws {
        let path = tempSocketPath()
        let server = try startServer(path)
        defer { server.stop() }

        let response = try IPCClient(socketPath: path).call(.status, NoParams(), as: StatusInfo.self)
        #expect(response.ok == false)
        #expect(throws: IPCFailure(.unsupported, "nope")) { try response.get() }
    }

    @Test func missingSocketIsATransportError() {
        #expect(throws: IPCError.self) {
            _ = try IPCClient(socketPath: tempSocketPath()).call(.hello, NoParams(), as: HelloInfo.self)
        }
    }

    @Test func socketFileIsOwnerOnly() throws {
        let path = tempSocketPath()
        let server = try startServer(path)
        defer { server.stop() }
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode.map { $0 & 0o077 } == 0)
    }

    @Test func oversizedRequestIsRejected() throws {
        let path = tempSocketPath()
        let server = try startServer(path)
        defer { server.stop() }

        let huge = Data(repeating: UInt8(ascii: "a"), count: MuninnLimits.maxRequestBytes + 10)
        let reply = try IPCClient(socketPath: path).send(huge)
        let response = try MuninnJSON.decoder().decode(IPCResponse<NoParams>.self, from: reply)
        #expect(response.error?.code == .invalidRequest)
    }

    @Test func slowRequestsRunConcurrently() async throws {
        let path = tempSocketPath()
        let server = try startServer(path, delay: .milliseconds(300))
        defer { server.stop() }

        let start = ContinuousClock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    _ = try IPCClient(socketPath: path).call(.hello, NoParams(), as: HelloInfo.self).get()
                }
            }
            try await group.waitForAll()
        }
        #expect(ContinuousClock.now - start < .milliseconds(1200), "five 300 ms requests shouldn't run one after another")
    }

    @Test func undecodableResponseIsReportedAsIncompatible() throws {
        let path = tempSocketPath()
        let server = IPCServer(socketPath: path) { _ in Data("{\"something\":\"else\"}".utf8) }
        try server.start()
        defer { server.stop() }
        let response = try IPCClient(socketPath: path).call(.hello, NoParams(), as: HelloInfo.self)
        #expect(response.error?.code == .incompatible)
    }
}

@Suite("IPC messages")
struct IPCMessageTests {
    @Test func errorCodesMapToCLIExitCodes() {
        #expect(IPCErrorCode.invalidRequest.exitCode == 1)
        #expect(IPCErrorCode.notFound.exitCode == 2)
        #expect(IPCErrorCode.internal.exitCode == 7)
        #expect(IPCErrorCode.incompatible.exitCode == 8)
        #expect(IPCErrorCode.busy.exitCode == 9)
    }

    @Test func datesAreISO8601UTCWithMilliseconds() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000.123)
        let json = String(decoding: try MuninnJSON.encoder().encode(["at": date]), as: UTF8.self)
        #expect(json == #"{"at":"2027-01-15T08:00:00.123Z"}"#)
        let back = try MuninnJSON.decoder().decode([String: Date].self, from: Data(json.utf8))
        #expect(abs(back["at"]!.timeIntervalSince(date)) < 0.001)
    }

    @Test func requestsEncodeMethodAndParams() throws {
        let data = try MuninnJSON.encoder().encode(IPCRequest(.get, ItemIDParams(id: 7)))
        #expect(String(decoding: data, as: UTF8.self) == #"{"method":"get","params":{"id":7},"version":2}"#)
        #expect(try MuninnJSON.decoder().decode(IPCRequestHeader.self, from: data).method == "get")
    }
}
