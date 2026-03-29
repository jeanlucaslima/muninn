import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelController: PanelController!
    private let hotKeyManager = HotKeyManager()

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
    }

    @objc private func statusItemClicked() {
        panelController.toggle()
    }
}
