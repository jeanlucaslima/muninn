import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelController: PanelController!
    private let hotKeyManager = HotKeyManager()
    private let helperManager = HelperManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "doc.on.clipboard",
                accessibilityDescription: "Muninn"
            )
            button.action = #selector(statusItemClicked)
            button.target = self
        }

        panelController = PanelController(statusItem: statusItem)

        hotKeyManager.register { [weak self] in
            DispatchQueue.main.async {
                self?.panelController.toggle()
            }
        }

        helperManager.start()

        if FirstRunManager.isFirstRun {
            // TODO: detect login-item launch vs user-initiated to avoid
            // showing setup panel unexpectedly on login-item startup.
            let setupViewModel = SetupViewModel(helperManager: helperManager)
            panelController.showSetup(viewModel: setupViewModel)
            panelController.open()
        }

        Task {
            await helperManager.waitForReady()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        helperManager.stop()
    }

    @objc private func statusItemClicked() {
        panelController.toggle()
    }
}
