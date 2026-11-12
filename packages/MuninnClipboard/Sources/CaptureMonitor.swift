import AppKit
import MuninnCore

/// One observed change that passed the capture policy, ready to persist.
public enum ObservedChange: Sendable, Equatable {
    case capture(CaptureInput)
    /// Muninn's own write of an existing item (§4.8).
    case selfCopy(itemID: Int64, at: Date, changeCount: Int)
}

public struct CaptureLimits: Sendable {
    public var maxRepresentationBytes = MuninnLimits.maxRepresentationBytes
    public var maxCaptureBytes = MuninnLimits.maxCaptureBytes
    public var maxFileReferences = MuninnLimits.maxFileReferences
    public var maxPendingCaptures = MuninnLimits.maxPendingCaptures

    public init() {}
}

/// Polls a pasteboard's `changeCount` (D6), applies `CapturePolicy`, reads
/// what it keeps and emits `ObservedChange`s. Lives on the main actor because
/// NSPasteboard does.
///
/// Not done yet: the `accessBehavior` onboarding (§4.16, PROOF-001), flood
/// limits and repeat coalescing (§4.14), read timeouts.
@MainActor
public final class CaptureMonitor {
    public let changes: AsyncStream<ObservedChange>
    public private(set) var counters = CaptureCounters()
    public private(set) var isPaused = false

    private let continuation: AsyncStream<ObservedChange>.Continuation
    private let pasteboard: NSPasteboard
    private let limits: CaptureLimits
    private var lastChangeCount: Int
    /// changeCounts produced by Muninn's own writes, not yet observed.
    private var ownWrites: Set<Int> = []
    private var pending = 0
    private var pollTask: Task<Void, Never>?

    public init(pasteboard: NSPasteboard = .general, limits: CaptureLimits = CaptureLimits()) {
        self.pasteboard = pasteboard
        self.limits = limits
        lastChangeCount = pasteboard.changeCount
        (changes, continuation) = AsyncStream.makeStream(of: ObservedChange.self)
    }

    public func start(interval: Duration = MuninnLimits.pollInterval) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        continuation.finish()
    }

    public func pause() {
        isPaused = true
    }

    /// Changes made while paused are neither read nor counted as missed.
    public func resume() {
        isPaused = false
        lastChangeCount = pasteboard.changeCount
        ownWrites.removeAll()
    }

    /// Call after Muninn writes the pasteboard, with the resulting changeCount,
    /// so the write isn't counted as a missed change.
    public func noteOwnWrite(changeCount: Int) {
        ownWrites.insert(changeCount)
    }

    /// The consumer calls this once it has persisted an emitted capture.
    public func didProcess() {
        pending = max(0, pending - 1)
    }

    public func recordStoreError() {
        counters.storeErrors += 1
    }

    // MARK: - Polling

    func poll(now: Date = Date()) {
        guard !isPaused else { return }
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }

        // Gap detection: changes between two polls that weren't our own writes.
        let intermediateOwn = ownWrites.filter { $0 > lastChangeCount && $0 < count }.count
        let missed = max(0, count - lastChangeCount - 1 - intermediateOwn)
        ownWrites = ownWrites.filter { $0 > count }
        lastChangeCount = count

        let types = (pasteboard.types ?? []).map(\.rawValue)
        let plan = CapturePolicy.plan(offeredTypes: types)
        if plan == .skipPrivacy {
            return // no trace, not even a counter (invariant 4)
        }
        counters.observedChanges += 1
        counters.missedChanges += missed

        switch plan {
        case .skipPrivacy:
            return
        case .selfCopy:
            let marker = pasteboard.string(forType: NSPasteboard.PasteboardType(MuninnPaths.selfCopyMarkerType))
            if let id = marker.flatMap({ Int64($0) }) {
                counters.selfCopies += 1
                continuation.yield(.selfCopy(itemID: id, at: now, changeCount: count))
            }
        case .nothingToKeep:
            counters.skippedUnsupported += 1
        case .read(let reads):
            // A capture that doesn't fit isn't read (§4.8 backpressure).
            guard pending < limits.maxPendingCaptures else {
                counters.droppedBackpressure += 1
                return
            }
            let input = CaptureInput(
                capturedAt: now,
                source: attributeSource(),
                changeCount: count,
                availableTypes: types,
                representations: read(reads)
            )
            pending += 1
            continuation.yield(.capture(input))
        }
    }

    // MARK: - Reading

    private func read(_ reads: [CapturePolicy.PlannedRead]) -> [RepresentationInput] {
        var total = 0
        var out: [RepresentationInput] = []

        func sized(_ payload: RepresentationPayload, bytes: Int) -> RepresentationPayload {
            guard bytes <= limits.maxRepresentationBytes, total + bytes <= limits.maxCaptureBytes else {
                counters.omittedBySize += 1
                return .omitted(.size)
            }
            total += bytes
            return payload
        }

        for planned in reads {
            let type = NSPasteboard.PasteboardType(planned.uti)
            switch planned.kind {
            case .text:
                if let string = pasteboard.string(forType: type) {
                    out.append(RepresentationInput(uti: planned.uti, role: planned.role,
                                                   payload: sized(.text(string), bytes: string.utf8.count)))
                } else if planned.role == .primary {
                    out.append(RepresentationInput(uti: planned.uti, role: .primary, payload: .omitted(.timeout)))
                }
            case .data:
                if let data = pasteboard.data(forType: type) {
                    out.append(RepresentationInput(uti: planned.uti, role: planned.role,
                                                   payload: sized(.data(data), bytes: data.count)))
                } else if planned.role == .primary {
                    out.append(RepresentationInput(uti: planned.uti, role: .primary, payload: .omitted(.timeout)))
                }
            case .fileURLs:
                // References only: the files themselves are never touched (§4.3).
                let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                                  options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
                if urls.isEmpty || urls.count > limits.maxFileReferences {
                    if !urls.isEmpty { counters.omittedBySize += 1 }
                    out.append(RepresentationInput(uti: planned.uti, role: .primary,
                                                   payload: .omitted(urls.isEmpty ? .timeout : .size)))
                } else {
                    for (n, url) in urls.enumerated() {
                        out.append(RepresentationInput(uti: planned.uti, role: n == 0 ? .primary : .alternate,
                                                       payload: .fileURL(url.absoluteString, fileSize: nil, modifiedAt: nil)))
                    }
                }
            }
        }
        return Self.promoteDeliveredPrimary(out)
    }

    /// A pasteboard can advertise a type and then deliver nothing (e.g. plain
    /// text "translated" from RTF). If the planned primary failed but something
    /// else was read, the first delivered representation becomes primary; the
    /// failed one stays recorded as omitted.
    nonisolated static func promoteDeliveredPrimary(_ reps: [RepresentationInput]) -> [RepresentationInput] {
        guard let primaryIndex = reps.firstIndex(where: { $0.role == .primary }),
              case .omitted(.timeout) = reps[primaryIndex].payload,
              let deliveredIndex = reps.firstIndex(where: {
                  if case .omitted = $0.payload { return false }
                  return true
              })
        else { return reps }
        var result = reps
        result[primaryIndex] = RepresentationInput(uti: reps[primaryIndex].uti, role: .alternate, payload: reps[primaryIndex].payload)
        result[deliveredIndex] = RepresentationInput(uti: reps[deliveredIndex].uti, role: .primary, payload: reps[deliveredIndex].payload)
        return result
    }

    /// `org.nspasteboard.source` when present (high confidence), otherwise
    /// the frontmost app (low).
    private func attributeSource() -> SourceApp {
        if let bundleID = pasteboard.string(forType: NSPasteboard.PasteboardType(CapturePolicy.sourceType)),
           !bundleID.isEmpty {
            let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            return SourceApp(bundleID: bundleID, name: name, confidence: .high)
        }
        if let app = NSWorkspace.shared.frontmostApplication {
            return SourceApp(bundleID: app.bundleIdentifier, name: app.localizedName, confidence: .low)
        }
        return .unknown
    }
}
