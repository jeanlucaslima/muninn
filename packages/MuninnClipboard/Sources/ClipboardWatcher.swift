import AppKit
import MuninnCore

public final class ClipboardWatcher: @unchecked Sendable {
    private let interval: TimeInterval
    private let onChange: @Sendable (String) -> Void
    private var lastChangeCount: Int
    private var timer: Timer?

    public init(interval: TimeInterval = 0.5, onChange: @escaping @Sendable (String) -> Void) {
        self.interval = interval
        self.onChange = onChange
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    public func start() {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        guard let content = pasteboard.string(forType: .string),
              !content.isEmpty else { return }

        onChange(content)
    }
}
