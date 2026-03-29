import AppKit
import MuninnCore

public final class ClipboardWatcher: @unchecked Sendable {
    private let interval: TimeInterval
    private let onChange: @Sendable (String) -> Void
    private var lastChangeCount: Int
    private var timer: Timer?

    private let pauseLock = NSLock()
    private var _isPaused = false

    public var paused: Bool {
        pauseLock.lock()
        defer { pauseLock.unlock() }
        return _isPaused
    }

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

    public func pause() {
        pauseLock.lock()
        defer { pauseLock.unlock() }
        _isPaused = true
    }

    public func resume() {
        pauseLock.lock()
        defer { pauseLock.unlock() }
        _isPaused = false
        lastChangeCount = NSPasteboard.general.changeCount
    }

    private func poll() {
        guard !paused else { return }

        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        // Skip clipboard writes made by Muninn itself
        if pasteboard.data(forType: MuninnPaths.pasteboardMarkerType) != nil {
            return
        }

        guard let content = pasteboard.string(forType: .string),
              !content.isEmpty else { return }

        onChange(content)
    }
}
