import Foundation
import MuninnCore

enum DaemonStatus {
    case connected
    case paused
    case unavailable
    case unknown
}

@MainActor
final class PanelViewModel: ObservableObject {
    @Published var searchText: String = ""
    @Published var entries: [ItemSummary] = []
    @Published var selectedIndex: Int = 0
    @Published var daemonStatus: DaemonStatus = .unknown
    @Published var totalCount: Int = 0

    var requestClose: (() -> Void)?

    private let daemon = DaemonClient()
    /// The in-flight load; a newer keystroke cancels it (§4.7 cancellation).
    private var loadTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?

    func onPanelOpen() {
        searchText = ""
        selectedIndex = 0
        entries = []
        reload(debounce: false)
        actionTask = Task { await fetchStatus() }
    }

    func onSearchTextChanged(_ newValue: String) {
        searchText = newValue
        reload(debounce: !newValue.isEmpty)
    }

    func copySelected() {
        guard let entry = selectedEntry else { return }
        actionTask = Task { try? await daemon.copy(id: entry.id) }
    }

    func deleteSelected() {
        guard let entry = selectedEntry else { return }
        entries.remove(at: selectedIndex)
        selectedIndex = min(selectedIndex, max(entries.count - 1, 0))
        actionTask = Task { try? await daemon.delete(id: entry.id) }
    }

    func togglePinSelected() {
        guard let entry = selectedEntry else { return }
        actionTask = Task {
            do {
                try await daemon.setPinned(id: entry.id, !entry.isPinned)
                reload(debounce: false, keepSelection: true)
            } catch {
                // The entry stays as it was.
            }
        }
    }

    func togglePause() {
        let pause = daemonStatus != .paused
        actionTask = Task {
            if let isPaused = try? await daemon.setPaused(pause) {
                daemonStatus = isPaused ? .paused : .connected
            }
        }
    }

    func moveSelectionUp() {
        guard !entries.isEmpty else { return }
        selectedIndex = max(selectedIndex - 1, 0)
    }

    func moveSelectionDown() {
        guard !entries.isEmpty else { return }
        selectedIndex = min(selectedIndex + 1, entries.count - 1)
    }

    var selectedEntry: ItemSummary? {
        guard selectedIndex >= 0, selectedIndex < entries.count else { return nil }
        return entries[selectedIndex]
    }

    // MARK: - Private

    private func reload(debounce: Bool, keepSelection: Bool = false) {
        loadTask?.cancel()
        let query = searchText
        loadTask = Task {
            if debounce {
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard !Task.isCancelled else { return }
            do {
                let page = query.isEmpty
                    ? try await daemon.list()
                    : try await daemon.search(query: query)
                guard !Task.isCancelled else { return }
                entries = page.items
                if query.isEmpty { totalCount = page.total }
                selectedIndex = keepSelection ? min(selectedIndex, max(entries.count - 1, 0)) : 0
                if daemonStatus == .unavailable || daemonStatus == .unknown {
                    daemonStatus = .connected
                }
            } catch is CancellationError {
                return
            } catch {
                daemonStatus = .unavailable
                entries = []
            }
        }
    }

    private func fetchStatus() async {
        do {
            let status = try await daemon.status()
            daemonStatus = status.isPaused ? .paused : .connected
            totalCount = status.itemCount
        } catch {
            daemonStatus = .unavailable
        }
    }
}

// MARK: - SearchFieldDelegate

extension PanelViewModel: SearchFieldDelegate {
    nonisolated func searchFieldDidChange(_ text: String) {
        Task { @MainActor in onSearchTextChanged(text) }
    }
    nonisolated func searchFieldMoveUp() {
        Task { @MainActor in moveSelectionUp() }
    }
    nonisolated func searchFieldMoveDown() {
        Task { @MainActor in moveSelectionDown() }
    }
    nonisolated func searchFieldConfirm() {
        Task { @MainActor in
            copySelected()
            requestClose?()
        }
    }
    nonisolated func searchFieldCancel() {
        Task { @MainActor in requestClose?() }
    }
    nonisolated func searchFieldDeleteEntry() {
        Task { @MainActor in deleteSelected() }
    }
    nonisolated func searchFieldTogglePin() {
        Task { @MainActor in togglePinSelected() }
    }
    nonisolated func searchFieldTogglePause() {
        Task { @MainActor in togglePause() }
    }
}
