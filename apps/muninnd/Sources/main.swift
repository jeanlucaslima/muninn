import Foundation
import os
import MuninnCore
import MuninnStore
import MuninnSearch
import MuninnClipboard
import MuninnIPC

// Composition root (design §4.1): creates every dependency once and wires them.
// Logs carry ids, counts and error categories only, never clipboard content (§4.15).

let log = Logger(subsystem: "com.muninn", category: "helper")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("muninnd: \(message)\n".utf8))
    exit(1)
}

do {
    try MuninnPaths.ensureDirectoryExists()
} catch {
    fail("cannot create the data directory: \(error)")
}

let writer: StoreWriter
let readers: ReaderPool
do {
    writer = try StoreWriter(path: MuninnPaths.databasePath)
    readers = try ReaderPool(path: MuninnPaths.databasePath)
} catch {
    fail("cannot open the store: \(error)")
}

let monitor = CaptureMonitor()

/// This process's physical footprint, as Activity Monitor reports it.
@Sendable func currentFootprint() -> Int64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let rc = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return rc == KERN_SUCCESS ? Int64(info.phys_footprint) : nil
}

/// The system `CaptureControl`: the pasteboard monitor and writer, on the main actor.
@MainActor
final class SystemCaptureControl: CaptureControl {
    let monitor: CaptureMonitor

    init(monitor: CaptureMonitor) {
        self.monitor = monitor
    }

    func pause() { monitor.pause() }
    func resume() { monitor.resume() }
    func state() -> (isPaused: Bool, counters: CaptureCounters) { (monitor.isPaused, monitor.counters) }

    func restore(itemID: Int64, representations: [RepresentationInput]) {
        let changeCount = PasteboardWriter.write(itemID: itemID, representations: representations)
        monitor.noteOwnWrite(changeCount: changeCount)
    }
}

let router = RequestRouter(
    writer: writer,
    readers: readers,
    search: SearchService(pool: readers),
    capture: SystemCaptureControl(monitor: monitor),
    startedAt: Date(),
    dataDirectory: MuninnPaths.applicationSupportDir,
    databasePath: MuninnPaths.databasePath,
    memoryFootprint: currentFootprint
)

// Persist observed changes in order. Capture never waits on this: the
// monitor only reads, and drops what doesn't fit (§4.8 backpressure).
let consumer = Task {
    for await change in monitor.changes {
        switch change {
        case .capture(let input):
            do {
                let outcome = try await writer.capture(input)
                log.debug("captured item \(outcome.itemID, privacy: .public)")
            } catch {
                monitor.recordStoreError()
                log.error("capture failed: \(String(describing: type(of: error)), privacy: .public)")
            }
            monitor.didProcess()
        case .selfCopy(let itemID, let at, let changeCount):
            do {
                try await writer.recordSelfCopy(itemID: itemID, at: at, changeCount: changeCount)
            } catch {
                monitor.recordStoreError()
                log.error("self-copy event failed: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }
}

let server = IPCServer(socketPath: MuninnPaths.socketPath) { data in
    await router.handle(data)
}
do {
    try server.start()
} catch {
    fail("cannot listen on the socket: \(error)")
}

monitor.start()
log.notice("ready (dev build: \(MuninnPaths.isDevBuild, privacy: .public))")
print("muninnd: ready, data in \(MuninnPaths.applicationSupportDir)")

let signalCallback: @convention(c) (Int32) -> Void = { _ in
    unlink(MuninnPaths.socketPath)
    exit(0)
}
signal(SIGINT, signalCallback)
signal(SIGTERM, signalCallback)

RunLoop.main.run()
