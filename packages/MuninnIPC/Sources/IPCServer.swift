import Foundation
import MuninnCore

#if canImport(Darwin)
import Darwin
#endif

// C-interop layer for the v1 Unix-socket transport, kept until D21 /
// PROOF-002 decide the transport (design §4.6). It has no peer
// authentication: any local process running as the user can connect.

/// One request line in, one response line out, per connection.
///
/// SAFETY (`@unchecked Sendable`): `serverFd` and `running` are written by
/// `start()`/`stop()` and read by the accept thread; a stale read only makes
/// the accept loop exit one iteration late. Each connection is handled on its
/// own thread and shares nothing else.
public final class IPCServer: @unchecked Sendable {
    private let socketPath: String
    private let handler: @Sendable (Data) async -> Data
    private var serverFd: Int32 = -1
    private var running = false

    public init(socketPath: String, handler: @escaping @Sendable (Data) async -> Data) {
        self.socketPath = socketPath
        self.handler = handler
    }

    public func start() throws {
        cleanupStaleSocket()

        serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            throw IPCError.socketCreationFailed(String(cString: strerror(errno)))
        }

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

        // Owner-only socket file.
        let oldMask = umask(0o077)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        guard bindResult == 0 else {
            close(serverFd)
            throw IPCError.bindFailed(String(cString: strerror(errno)))
        }

        guard listen(serverFd, 16) == 0 else {
            close(serverFd)
            unlink(socketPath)
            throw IPCError.listenFailed(String(cString: strerror(errno)))
        }

        running = true
        Thread.detachNewThread { [weak self] in
            self?.acceptLoop()
        }
    }

    public func stop() {
        running = false
        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }
        unlink(socketPath)
    }

    // MARK: - Private

    private func acceptLoop() {
        while running {
            let clientFd = accept(serverFd, nil, nil)
            guard clientFd >= 0 else {
                if running { continue }
                break
            }
            Thread.detachNewThread { [weak self] in
                self?.handleConnection(clientFd)
            }
        }
    }

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }

        let response: Data
        switch readLine(from: fd) {
        case .none:
            return
        case .some(.tooLarge):
            response = Self.failure(IPCFailure(.invalidRequest, "request larger than \(MuninnLimits.maxRequestBytes) bytes"))
        case .some(.line(let line)):
            // Bridge this connection thread to the async handler. The thread
            // is a dedicated one (not the cooperative pool), so blocking it is fine.
            let box = ResponseBox()
            let done = DispatchSemaphore(value: 0)
            let handler = self.handler
            Task {
                box.data = await handler(line)
                done.signal()
            }
            done.wait()
            response = box.data
        }
        writeLine(to: fd, data: response)
    }

    private enum ReadResult {
        case line(Data)
        case tooLarge
    }

    private func readLine(from fd: Int32) -> ReadResult? {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var accumulated = Data()

        while true {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            accumulated.append(contentsOf: buffer[..<bytesRead])
            if accumulated.count > MuninnLimits.maxRequestBytes { return .tooLarge }
            if accumulated.contains(UInt8(ascii: "\n")) { break }
        }

        guard !accumulated.isEmpty else { return nil }
        if let newline = accumulated.firstIndex(of: UInt8(ascii: "\n")) {
            accumulated = accumulated[accumulated.startIndex..<newline]
        }
        return .line(Data(accumulated))
    }

    private func writeLine(to fd: Int32, data: Data) {
        var payload = data
        payload.append(UInt8(ascii: "\n"))
        payload.withUnsafeBytes { ptr in
            guard var base = ptr.baseAddress else { return }
            var remaining = payload.count
            while remaining > 0 {
                let written = write(fd, base, remaining)
                if written <= 0 { return }
                remaining -= written
                base += written
            }
        }
    }

    static func failure(_ error: IPCFailure) -> Data {
        (try? MuninnJSON.encoder().encode(IPCResponse<NoParams>.failure(error))) ?? Data()
    }

    private func cleanupStaleSocket() {
        guard FileManager.default.fileExists(atPath: socketPath) else { return }

        let testFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard testFd >= 0 else {
            unlink(socketPath)
            return
        }
        defer { close(testFd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: socketPath.utf8CString.count) { dest in
                for (i, byte) in socketPath.utf8CString.enumerated() {
                    dest[i] = byte
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(testFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if connectResult != 0 {
            unlink(socketPath)
        }
        // If connect succeeded, someone is already listening; bind fails, correctly.
    }
}

/// SAFETY: written once by the handler task before `signal()`, read once by
/// the connection thread after `wait()`; the semaphore orders the two.
private final class ResponseBox: @unchecked Sendable {
    var data = Data()
}

public enum IPCError: Error, CustomStringConvertible {
    case socketCreationFailed(String)
    case bindFailed(String)
    case listenFailed(String)
    case pathTooLong
    case connectionFailed(String)
    case sendFailed
    case receiveFailed

    public var description: String {
        switch self {
        case .socketCreationFailed(let msg): return "Socket creation failed: \(msg)"
        case .bindFailed(let msg): return "Bind failed: \(msg)"
        case .listenFailed(let msg): return "Listen failed: \(msg)"
        case .pathTooLong: return "Socket path too long"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .sendFailed: return "Send failed"
        case .receiveFailed: return "Receive failed"
        }
    }
}
