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

    // MARK: - IPCResponse

    @Test("IPCResponse.failure sets ok to false")
    func failureResponse() throws {
        let response = IPCResponse<String>.failure("something went wrong")
        #expect(response.ok == false)
        #expect(response.error == "something went wrong")
        #expect(response.data == nil)
    }

    @Test("IPCResponse.failure with detail sets category and message")
    func failureWithDetail() throws {
        let response = IPCResponse<String>.failure(.notFound("entry not found: 42"))
        #expect(response.ok == false)
        #expect(response.error == "entry not found: 42")
        #expect(response.errorDetail?.category == "not_found")
    }

    // MARK: - IPCRequest encoding/decoding

    @Test("Roundtrip encoding for search request")
    func searchRequestRoundtrip() throws {
        let request = IPCRequest(method: "search", params: .search(.init(query: "hello", limit: 10)))
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(request)
        let decoded = try decoder.decode(IPCRequest.self, from: data)

        #expect(decoded.method == "search")
        guard case .search(let params) = decoded.params else {
            Issue.record("expected search params"); return
        }
        #expect(params.query == "hello")
        #expect(params.limit == 10)
    }

    @Test("Roundtrip encoding for copy request")
    func copyRequestRoundtrip() throws {
        let request = IPCRequest(method: "copy", params: .copy(.init(id: 42)))
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(request)
        let decoded = try decoder.decode(IPCRequest.self, from: data)

        #expect(decoded.method == "copy")
        guard case .copy(let params) = decoded.params else {
            Issue.record("expected copy params"); return
        }
        #expect(params.id == 42)
    }

    @Test("Roundtrip encoding for delete request")
    func deleteRequestRoundtrip() throws {
        let request = IPCRequest(method: "delete", params: .delete(.init(id: 7)))
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(request)
        let decoded = try decoder.decode(IPCRequest.self, from: data)

        #expect(decoded.method == "delete")
        guard case .delete(let params) = decoded.params else {
            Issue.record("expected delete params"); return
        }
        #expect(params.id == 7)
    }

    @Test("Roundtrip encoding for pin/unpin requests")
    func pinUnpinRequestRoundtrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let pinReq = IPCRequest(method: "pin", params: .pin(.init(id: 5)))
        let pinData = try encoder.encode(pinReq)
        let pinDecoded = try decoder.decode(IPCRequest.self, from: pinData)
        #expect(pinDecoded.method == "pin")
        guard case .pin(let pinParams) = pinDecoded.params else {
            Issue.record("expected pin params"); return
        }
        #expect(pinParams.id == 5)

        let unpinReq = IPCRequest(method: "unpin", params: .unpin(.init(id: 5)))
        let unpinData = try encoder.encode(unpinReq)
        let unpinDecoded = try decoder.decode(IPCRequest.self, from: unpinData)
        #expect(unpinDecoded.method == "unpin")
        guard case .unpin(let unpinParams) = unpinDecoded.params else {
            Issue.record("expected unpin params"); return
        }
        #expect(unpinParams.id == 5)
    }

    @Test("Roundtrip encoding for pause/resume requests")
    func pauseResumeRequestRoundtrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let pauseReq = IPCRequest(method: "pause", params: .pause)
        let pauseData = try encoder.encode(pauseReq)
        let pauseDecoded = try decoder.decode(IPCRequest.self, from: pauseData)
        #expect(pauseDecoded.method == "pause")

        let resumeReq = IPCRequest(method: "resume", params: .resume)
        let resumeData = try encoder.encode(resumeReq)
        let resumeDecoded = try decoder.decode(IPCRequest.self, from: resumeData)
        #expect(resumeDecoded.method == "resume")
    }

    @Test("Unknown method decodes with empty params")
    func unknownMethodDecodes() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let request = IPCRequest(method: "nonexistent", params: .empty)
        let data = try encoder.encode(request)
        let decoded = try decoder.decode(IPCRequest.self, from: data)

        #expect(decoded.method == "nonexistent")
        guard case .empty = decoded.params else {
            Issue.record("expected empty params for unknown method"); return
        }
    }
}
