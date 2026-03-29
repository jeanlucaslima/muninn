import AppKit

@MainActor
final class SetupViewModel: ObservableObject {
    @Published var launchAtLogin = false
    @Published var installCLI = false
    @Published var loginError: String?
    @Published var cliError: String?
    @Published var cliInstalledPath: String?

    let helperManager: HelperManager
    var onComplete: (() -> Void)?

    init(helperManager: HelperManager) {
        self.helperManager = helperManager
    }

    var canDismiss: Bool {
        helperManager.status != .starting
    }

    var helperFailed: Bool {
        helperManager.status == .failed
    }

    func done() {
        if launchAtLogin {
            if !LoginItemManager.enable() {
                loginError = "Could not enable. Try again in System Settings."
                launchAtLogin = false
            }
        }

        if installCLI {
            switch CLIInstaller.install() {
            case .installed(let path):
                cliInstalledPath = path
            case .failed(let reason):
                cliError = reason
                installCLI = false
            }
        }

        if helperManager.helperLaunched {
            FirstRunManager.markComplete()
        }

        onComplete?()
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}
