import AppKit
import SwiftUI

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let panel: KeyablePanel
    private let statusItem: NSStatusItem
    private let viewModel = PanelViewModel()

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem

        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init()

        viewModel.requestClose = { [weak self] in
            self?.close()
        }

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .windowBackgroundColor
        panel.acceptsMouseMovedEvents = true

        let hostingView = NSHostingView(rootView: PanelContentView(viewModel: viewModel))
        panel.contentView = hostingView
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible {
            close()
        } else {
            open()
        }
    }

    func open() {
        viewModel.onPanelOpen()
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel.orderOut(nil)
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in
            close()
        }
    }

    private func positionPanel() {
        guard let buttonFrame = statusItem.button?.window?.frame else { return }
        guard let screen = NSScreen.main else { return }

        let panelWidth = panel.frame.width
        let panelHeight = panel.frame.height

        var x = buttonFrame.midX - panelWidth / 2
        let y = buttonFrame.minY - panelHeight

        let visibleFrame = screen.visibleFrame
        x = max(visibleFrame.minX, min(x, visibleFrame.maxX - panelWidth))

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
