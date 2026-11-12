import Foundation
import MuninnCore
import MuninnIPC

enum HelperStatus: Sendable {
    case starting
    case running
    case failed
}

@MainActor
final class HelperManager: ObservableObject {
    @Published private(set) var status: HelperStatus = .starting
    @Published private(set) var helperLaunched = false

    private var process: Process?
    private var hasRestarted = false

    func start() {
        guard let path = MuninnPaths.helperExecutablePath else {
            print("muninn: helper binary not found")
            status = .failed
            return
        }

        launchProcess(at: path)
    }

    func stop() {
        guard let process = process, process.isRunning else { return }
        process.terminate()
    }

    func waitForReady() async {
        let client = IPCClient(socketPath: MuninnPaths.socketPath)
        let maxAttempts = 100 // 10 seconds at 100ms intervals
        for _ in 0..<maxAttempts {
            try? await Task.sleep(for: .milliseconds(100))
            // A refused connection fails immediately, so this doesn't stall the main actor.
            if (try? client.call(.hello, NoParams(), as: HelloInfo.self).get()) != nil {
                status = .running
                return
            }
        }
        status = .failed
    }

    // MARK: - Private

    private func launchProcess(at path: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["run"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] terminatedProcess in
            DispatchQueue.main.async {
                self?.handleTermination(terminatedProcess, binaryPath: path)
            }
        }

        do {
            try proc.run()
            process = proc
            helperLaunched = true
            status = .starting
            print("muninn: helper started (pid \(proc.processIdentifier))")
        } catch {
            print("muninn: failed to launch helper: \(error)")
            status = .failed
        }
    }

    private func handleTermination(_ process: Process, binaryPath: String) {
        let code = process.terminationStatus
        print("muninn: helper exited (status \(code))")

        guard status == .running else {
            status = .failed
            return
        }

        guard !hasRestarted else {
            print("muninn: helper already restarted once, not retrying")
            status = .failed
            return
        }

        print("muninn: attempting one restart")
        hasRestarted = true
        launchProcess(at: binaryPath)

        Task {
            await waitForReady()
        }
    }
}
