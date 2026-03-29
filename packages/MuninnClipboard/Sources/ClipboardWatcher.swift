import AppKit
import MuninnCore

public struct ClipboardCapture: Sendable {
    public let kind: EntryKind
    public let content: String
    public let metadata: EntryMetadata?

    public init(kind: EntryKind, content: String, metadata: EntryMetadata?) {
        self.kind = kind
        self.content = content
        self.metadata = metadata
    }
}

public final class ClipboardWatcher: @unchecked Sendable {
    private let interval: TimeInterval
    private let onChange: @Sendable (ClipboardCapture) -> Void
    private var lastChangeCount: Int
    private var timer: Timer?

    private let pauseLock = NSLock()
    private var _isPaused = false

    public var paused: Bool {
        pauseLock.lock()
        defer { pauseLock.unlock() }
        return _isPaused
    }

    public init(interval: TimeInterval = 0.5, onChange: @escaping @Sendable (ClipboardCapture) -> Void) {
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

        let types = pasteboard.types ?? []

        // Priority 1: text (handles mixed clipboard like text + image)
        if types.contains(.string),
           let text = pasteboard.string(forType: .string),
           !text.isEmpty {
            onChange(ClipboardCapture(kind: .text, content: text, metadata: nil))
            return
        }

        // Priority 2: image
        if types.contains(.tiff) || types.contains(.png) {
            var meta: EntryMetadata? = nil
            if let image = NSImage(pasteboard: pasteboard) {
                let size = image.size
                meta = EntryMetadata(width: Int(size.width), height: Int(size.height))
            }
            onChange(ClipboardCapture(kind: .image, content: "", metadata: meta))
            return
        }

        // Priority 3: file URL(s)
        if types.contains(.fileURL) {
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
                .urlReadingFileURLsOnly: true
            ]) as? [URL] ?? []

            if urls.count == 1, let url = urls.first {
                let meta = EntryMetadata(name: url.lastPathComponent, path: url.path)
                onChange(ClipboardCapture(kind: .file, content: "", metadata: meta))
            } else if urls.count > 1 {
                let names = urls.prefix(20).map(\.lastPathComponent)
                let meta = EntryMetadata(count: urls.count, names: Array(names))
                onChange(ClipboardCapture(kind: .files, content: "", metadata: meta))
            }
            return
        }

        // Priority 4: rich text
        if types.contains(.rtf) {
            onChange(ClipboardCapture(kind: .richText, content: "", metadata: nil))
            return
        }

        // Priority 5: HTML
        if types.contains(.html) {
            onChange(ClipboardCapture(kind: .html, content: "", metadata: nil))
            return
        }

        // Priority 6: unknown (something is on the clipboard but unrecognized)
        if !types.isEmpty {
            onChange(ClipboardCapture(kind: .unknown, content: "", metadata: nil))
        }
    }
}
