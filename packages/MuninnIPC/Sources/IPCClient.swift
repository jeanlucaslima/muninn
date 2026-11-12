import Foundation
import MuninnCore

#if canImport(Darwin)
import Darwin
#endif

/// Blocking client for the v1 socket transport: one request per connection.
public struct IPCClient: Sendable {
    private let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Sends one request and decodes the response envelope. Transport
    /// failures throw `IPCError`; a helper-side failure is in the envelope.
    public func call<P: Codable & Sendable, T: Codable & Sendable>(
        _ method: IPCMethod, _ params: P, as type: T.Type = T.self
    ) throws -> IPCResponse<T> {
        let request = try MuninnJSON.encoder().encode(IPCRequest(method, params))
        let response = try send(request)
        do {
            return try MuninnJSON.decoder().decode(IPCResponse<T>.self, from: response)
        } catch {
            // A helper speaking another protocol version can't be decoded.
            return .failure(IPCFailure(.incompatible, "could not decode the helper's response: \(error)"))
        }
    }

    public func send(_ payload: Data) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IPCError.socketCreationFailed(String(cString: strerror(errno)))
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw IPCError.pathTooLong
        }
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

        var message = payload
        message.append(UInt8(ascii: "\n"))
        let ok = message.withUnsafeBytes { ptr -> Bool in
            guard var base = ptr.baseAddress else { return false }
            var remaining = message.count
            while remaining > 0 {
                let written = write(fd, base, remaining)
                if written <= 0 { return false }
                remaining -= written
                base += written
            }
            return true
        }
        guard ok else { throw IPCError.sendFailed }
        shutdown(fd, SHUT_WR)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            response.append(contentsOf: buffer[..<bytesRead])
        }
        guard !response.isEmpty else { throw IPCError.receiveFailed }
        if response.last == UInt8(ascii: "\n") {
            response.removeLast()
        }
        return response
    }
}
