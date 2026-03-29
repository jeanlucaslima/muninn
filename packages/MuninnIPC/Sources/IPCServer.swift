import Foundation
import MuninnCore

#if canImport(Darwin)
import Darwin
#endif

public final class IPCServer: @unchecked Sendable {
    private let socketPath: String
    private let handler: @Sendable (IPCRequest) throws -> Data
    private var serverFd: Int32 = -1
    private var running = false

    public init(socketPath: String, handler: @escaping @Sendable (IPCRequest) throws -> Data) {
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

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(serverFd)
            throw IPCError.bindFailed(String(cString: strerror(errno)))
        }

        guard listen(serverFd, 5) == 0 else {
            close(serverFd)
            unlink(socketPath)
            throw IPCError.listenFailed(String(cString: strerror(errno)))
        }

        running = true

        // Accept connections on a background thread
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
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(serverFd, sockPtr, &clientAddrLen)
                }
            }

            guard clientFd >= 0 else {
                if running { continue }
                break
            }

            // Handle each connection on a detached thread
            Thread.detachNewThread { [weak self] in
                self?.handleConnection(clientFd)
            }
        }
    }

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }

        guard let line = readLine(from: fd) else { return }

        let decoder = JSONDecoder()
        do {
            let request = try decoder.decode(IPCRequest.self, from: Data(line.utf8))
            let responseData = try handler(request)
            writeLine(to: fd, data: responseData)
        } catch {
            let errorResponse = #"{"ok":false,"error":"\#(error.localizedDescription)"}"#
            writeLine(to: fd, data: Data(errorResponse.utf8))
        }
    }

    private func readLine(from fd: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var accumulated = Data()

        while true {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            accumulated.append(contentsOf: buffer[..<bytesRead])
            if accumulated.contains(UInt8(ascii: "\n")) { break }
        }

        guard !accumulated.isEmpty else { return nil }
        // Strip trailing newline
        if accumulated.last == UInt8(ascii: "\n") {
            accumulated.removeLast()
        }
        return String(data: accumulated, encoding: .utf8)
    }

    private func writeLine(to fd: Int32, data: Data) {
        var payload = data
        payload.append(UInt8(ascii: "\n"))
        payload.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            _ = write(fd, base, payload.count)
        }
    }

    private func cleanupStaleSocket() {
        guard FileManager.default.fileExists(atPath: socketPath) else { return }

        // Try to connect — if it fails, the socket is stale
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
            // Stale socket — remove it
            unlink(socketPath)
        }
        // If connect succeeded, someone is already listening — we'll fail on bind (correct behavior)
    }
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
