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
    @Published var entries: [ClipboardEntry] = []
    @Published var selectedIndex: Int = 0
    @Published var daemonStatus: DaemonStatus = .unknown
    @Published var totalCount: Int = 0

    var requestClose: (() -> Void)?

    private let daemon = DaemonClient()
    private var searchWorkItem: DispatchWorkItem?

    func onPanelOpen() {
        searchText = ""
        selectedIndex = 0
        entries = []

        Task {
            await loadInitial()
        }
    }

    func onSearchTextChanged(_ newValue: String) {
        searchText = newValue
        searchWorkItem?.cancel()

        if newValue.isEmpty {
            Task { await performList() }
            return
        }

        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                await self?.performSearch(newValue)
            }
        }
        searchWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    func copySelected() {
        guard let entry = selectedEntry, entry.kind == .text else { return }
        Task {
            try? await daemon.copy(id: entry.id)
        }
    }

    func deleteSelected() {
        guard let entry = selectedEntry else { return }
        let removedIndex = selectedIndex
        entries.remove(at: removedIndex)
        selectedIndex = min(selectedIndex, max(entries.count - 1, 0))

        Task {
            try? await daemon.delete(id: entry.id)
        }
    }

    func togglePinSelected() {
        guard let entry = selectedEntry else { return }
        let index = selectedIndex

        Task {
            do {
                let updated: ClipboardEntry
                if entry.isPinned {
                    updated = try await daemon.unpin(id: entry.id)
                } else {
                    updated = try await daemon.pin(id: entry.id)
                }
                if index < entries.count, entries[index].id == entry.id {
                    entries[index] = updated
                }
            } catch {
                // Silent failure — entry stays in current state
            }
        }
    }

    func togglePause() {
        Task {
            do {
                let isPaused: Bool
                if daemonStatus == .paused {
                    isPaused = try await daemon.resume()
                } else {
                    isPaused = try await daemon.pause()
                }
                daemonStatus = isPaused ? .paused : .connected
            } catch {
                // Silent failure
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

    var selectedEntry: ClipboardEntry? {
        guard selectedIndex >= 0, selectedIndex < entries.count else { return nil }
        return entries[selectedIndex]
    }

    // MARK: - Private

    private func loadInitial() async {
        async let statusTask: Void = fetchStatus()
        async let listTask: Void = performList()
        _ = await (statusTask, listTask)
    }

    private func fetchStatus() async {
        do {
            let status = try await daemon.status()
            daemonStatus = status.isPaused ? .paused : .connected
            totalCount = status.entryCount
        } catch {
            daemonStatus = .unavailable
        }
    }

    private func performList() async {
        do {
            let result = try await daemon.list()
            entries = result.entries
            totalCount = result.total
            selectedIndex = 0
            if daemonStatus == .unavailable || daemonStatus == .unknown {
                daemonStatus = .connected
            }
        } catch {
            daemonStatus = .unavailable
            entries = []
        }
    }

    private func performSearch(_ query: String) async {
        do {
            let result = try await daemon.search(query: query)
            entries = result.entries
            selectedIndex = 0
            if daemonStatus == .unavailable || daemonStatus == .unknown {
                daemonStatus = .connected
            }
        } catch {
            daemonStatus = .unavailable
            entries = []
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
