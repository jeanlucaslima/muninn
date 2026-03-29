import Testing
import Foundation
@testable import MuninnIPC
@testable import MuninnCore

@Suite("IPC")
struct IPCTests {
    @Test("Roundtrip request and response over socket")
    func roundtrip() throws {
        let socketPath = NSTemporaryDirectory() + "muninn-test-\(UUID().uuidString).sock"
        defer { unlink(socketPath) }

        let server = IPCServer(socketPath: socketPath) { request in
            let encoder = JSONEncoder()
            if request.method == "echo" {
                let response = IPCResponse(ok: true, data: "echoed", error: nil)
                return try encoder.encode(response)
            } else {
                let response = IPCResponse<String>(ok: false, data: nil, error: "unknown")
                return try encoder.encode(response)
            }
        }

        try server.start()
        defer { server.stop() }

        // Give server a moment to start
        Thread.sleep(forTimeInterval: 0.1)

        let client = IPCClient(socketPath: socketPath)
        let request = IPCRequest(method: "echo", params: .empty)
        let response = try client.sendAndDecode(request, as: IPCResponse<String>.self)

        #expect(response.ok == true)
        #expect(response.data == "echoed")
    }

    @Test("Client gets error for connection to nonexistent socket")
    func connectionFailure() throws {
        let client = IPCClient(socketPath: "/tmp/muninn-nonexistent-\(UUID().uuidString).sock")
        let request = IPCRequest(method: "test", params: .empty)

        #expect(throws: IPCError.self) {
            try client.send(request)
        }
    }
}
