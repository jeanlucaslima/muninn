import Foundation
import MuninnCore

#if canImport(Darwin)
import Darwin
#endif

public final class IPCClient: Sendable {
    private let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func send(_ request: IPCRequest) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IPCError.socketCreationFailed(String(cString: strerror(errno)))
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw IPCError.connectionFailed(String(cString: strerror(errno)))
        }

        // Send request as JSON line
        let encoder = JSONEncoder()
        var payload = try encoder.encode(request)
        payload.append(UInt8(ascii: "\n"))

        let written = payload.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return -1 }
            return write(fd, base, payload.count)
        }
        guard written == payload.count else {
            throw IPCError.sendFailed
        }

        // Shutdown write side so server sees EOF
        shutdown(fd, SHUT_WR)

        // Read response
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            response.append(contentsOf: buffer[..<bytesRead])
        }

        guard !response.isEmpty else {
            throw IPCError.receiveFailed
        }

        // Strip trailing newline
        if response.last == UInt8(ascii: "\n") {
            response.removeLast()
        }

        return response
    }

    /// Convenience: send a request and decode the response.
    public func sendAndDecode<T: Codable & Sendable>(_ request: IPCRequest, as type: IPCResponse<T>.Type) throws -> IPCResponse<T> {
        let data = try send(request)
        let decoder = JSONDecoder()
        return try decoder.decode(IPCResponse<T>.self, from: data)
    }
}
