import Testing
import AppKit
import MuninnCore
@testable import MuninnClipboard

// Every test uses a uniquely named private pasteboard, never the user's clipboard.

let plain = "public.utf8-plain-text"

@Suite("CapturePolicy")
struct CapturePolicyTests {
    func reads(_ types: [String]) -> [String] {
        guard case .read(let reads) = CapturePolicy.plan(offeredTypes: types) else { return [] }
        return reads.map { "\($0.uti):\($0.role.rawValue)" }
    }

    @Test func privacyTypesSkipEverything() {
        for type in CapturePolicy.privacyTypes {
            #expect(CapturePolicy.plan(offeredTypes: [plain, type]) == .skipPrivacy)
        }
    }

    @Test func selfCopyMarkerIsRecognized() {
        #expect(CapturePolicy.plan(offeredTypes: [plain, MuninnPaths.selfCopyMarkerType]) == .selfCopy)
    }

    @Test func plainTextIsPrimaryWithRichAlternates() {
        #expect(reads([plain, "public.html", "public.rtf"])
                == ["\(plain):primary", "public.rtf:alternate", "public.html:alternate"])
    }

    @Test func richTextWithoutPlainBecomesPrimary() {
        #expect(reads(["public.rtf"]) == ["public.rtf:primary"])
    }

    @Test func compactRasterIsPreferredOverTIFF() {
        #expect(reads(["public.tiff", "public.png"]) == ["public.png:primary"])
        #expect(reads(["public.tiff"]) == ["public.tiff:primary"])
    }

    @Test func fileReferencesIgnoreFinderExtras() {
        #expect(reads(["public.file-url", plain, "public.tiff"]) == ["public.file-url:primary"])
    }

    @Test func appPrivateTypesAloneAreNothingToKeep() {
        #expect(CapturePolicy.plan(offeredTypes: ["com.example.private", "dyn.ah62d4rv4ge80"]) == .nothingToKeep)
        #expect(CapturePolicy.plan(offeredTypes: []) == .nothingToKeep)
    }
}

@MainActor
@Suite("CaptureMonitor")
final class CaptureMonitorTests {
    let pasteboard = NSPasteboard.withUniqueName()

    isolated deinit {
        pasteboard.releaseGlobally()
    }

    func put(_ values: [String: String]) {
        pasteboard.clearContents()
        for (type, value) in values {
            pasteboard.setString(value, forType: NSPasteboard.PasteboardType(type))
        }
    }

    /// Polls once and returns what was emitted, if anything.
    func pollOnce(_ monitor: CaptureMonitor) async -> ObservedChange? {
        monitor.poll()
        var iterator = monitor.changes.makeAsyncIterator()
        let race = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            monitor.stop()
        }
        defer { race.cancel() }
        return await iterator.next()
    }

    func input(_ change: ObservedChange?) -> CaptureInput? {
        if case .capture(let input) = change { return input }
        return nil
    }

    @Test func capturesTextWithHighConfidenceSource() async throws {
        let monitor = CaptureMonitor(pasteboard: pasteboard)
        put([plain: "hello", "public.html": "<b>hello</b>", CapturePolicy.sourceType: "com.example.editor"])
        let captured = try #require(input(await pollOnce(monitor)))
        #expect(captured.representations.map(\.uti) == [plain, "public.html"])
        #expect(captured.representations.first?.payload == .text("hello"))
        #expect(captured.source.bundleID == "com.example.editor")
        #expect(captured.source.confidence == .high)
        #expect(captured.changeCount == pasteboard.changeCount)
        #expect(monitor.counters.observedChanges == 1)
    }

    @Test func privacySkipLeavesNoTrace() async {
        let monitor = CaptureMonitor(pasteboard: pasteboard)
        put([plain: "s3cret", "org.nspasteboard.ConcealedType": ""])
        #expect(await pollOnce(monitor) == nil)
        #expect(monitor.counters == CaptureCounters())
    }

    @Test func gapsBetweenPollsAreCountedAsMissed() async {
        let monitor = CaptureMonitor(pasteboard: pasteboard)
        put([plain: "one"])
        put([plain: "two"])
        put([plain: "three"])
        let captured = input(await pollOnce(monitor))
        #expect(captured?.representations.first?.payload == .text("three"))
        #expect(monitor.counters.missedChanges == 2)
    }

    @Test func ownWritesAreNotMissedAndRecordedAsSelfCopies() async {
        let monitor = CaptureMonitor(pasteboard: pasteboard)
        let count = PasteboardWriter.write(
            itemID: 42,
            representations: [RepresentationInput(uti: plain, role: .primary, payload: .text("restored"))],
            to: pasteboard)
        monitor.noteOwnWrite(changeCount: count)
        #expect(pasteboard.string(forType: .string) == "restored")

        let change = await pollOnce(monitor)
        guard case .selfCopy(let itemID, _, let changeCount) = change else {
            Issue.record("expected a self-copy, got \(String(describing: change))")
            return
        }
        #expect(itemID == 42)
        #expect(changeCount == count)
        #expect(monitor.counters.selfCopies == 1)
        #expect(monitor.counters.missedChanges == 0)
    }

    @Test func oversizedRepresentationIsOmittedNotTruncated() async throws {
        var limits = CaptureLimits()
        limits.maxRepresentationBytes = 3
        let monitor = CaptureMonitor(pasteboard: pasteboard, limits: limits)
        put([plain: "hello"])
        let captured = try #require(input(await pollOnce(monitor)))
        #expect(captured.representations.first?.payload == .omitted(.size))
        #expect(monitor.counters.omittedBySize == 1)
    }

    @Test func backpressureDropsWhatDoesntFit() async {
        var limits = CaptureLimits()
        limits.maxPendingCaptures = 1
        let monitor = CaptureMonitor(pasteboard: pasteboard, limits: limits)
        put([plain: "first"])
        monitor.poll()
        put([plain: "second"])
        monitor.poll()
        #expect(monitor.counters.droppedBackpressure == 1)
        monitor.didProcess()
        put([plain: "third"])
        monitor.poll()
        #expect(monitor.counters.droppedBackpressure == 1)
    }

    @Test func changesWhilePausedAreIgnored() async {
        let monitor = CaptureMonitor(pasteboard: pasteboard)
        monitor.pause()
        put([plain: "while paused"])
        monitor.poll()
        monitor.resume()
        #expect(await pollOnce(monitor) == nil)
        #expect(monitor.counters == CaptureCounters())
    }

    @Test func fileReferencesAreKeptWithoutTouchingFiles() async throws {
        let monitor = CaptureMonitor(pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/muninn-a.txt") as NSURL,
                                 URL(fileURLWithPath: "/tmp/muninn-b.txt") as NSURL])
        let captured = try #require(input(await pollOnce(monitor)))
        #expect(captured.representations.map(\.payload) == [
            .fileURL("file:///tmp/muninn-a.txt", fileSize: nil, modifiedAt: nil),
            .fileURL("file:///tmp/muninn-b.txt", fileSize: nil, modifiedAt: nil),
        ])
        #expect(captured.representations.map(\.role) == [.primary, .alternate])
    }

    /// Found in a real run: `pbcopy -Prefer rtf` makes the system pasteboard
    /// advertise plain text that reads back as nil. A private pasteboard
    /// converts RTF itself, so the rule is tested directly.
    @Test func undeliveredPrimaryIsReplacedByWhatWasRead() {
        let rtf = Data("{\\rtf1 hi}".utf8)
        let promoted = CaptureMonitor.promoteDeliveredPrimary([
            RepresentationInput(uti: plain, role: .primary, payload: .omitted(.timeout)),
            RepresentationInput(uti: "public.rtf", role: .alternate, payload: .data(rtf)),
        ])
        #expect(promoted.map(\.role) == [.alternate, .primary])
        #expect(promoted.first?.payload == .omitted(.timeout))
        #expect(promoted.last?.payload == .data(rtf))

        // Nothing delivered, or a size omission: unchanged.
        let nothing = [RepresentationInput(uti: plain, role: .primary, payload: .omitted(.timeout))]
        #expect(CaptureMonitor.promoteDeliveredPrimary(nothing) == nothing)
        let tooBig = [
            RepresentationInput(uti: plain, role: .primary, payload: .omitted(.size)),
            RepresentationInput(uti: "public.rtf", role: .alternate, payload: .data(rtf)),
        ]
        #expect(CaptureMonitor.promoteDeliveredPrimary(tooBig) == tooBig)
    }

    @Test func writerRestoresDataAndFileItems() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        PasteboardWriter.write(itemID: 7, representations: [
            RepresentationInput(uti: "public.png", role: .primary, payload: .data(png)),
            RepresentationInput(uti: plain, role: .alternate, payload: .text("caption")),
        ], to: pasteboard)
        #expect(pasteboard.data(forType: .png) == png)
        #expect(pasteboard.string(forType: .string) == "caption")
        #expect(pasteboard.string(forType: NSPasteboard.PasteboardType(MuninnPaths.selfCopyMarkerType)) == "7")

        PasteboardWriter.write(itemID: 8, representations: [
            RepresentationInput(uti: "public.file-url", role: .primary, payload: .fileURL("file:///tmp/x", fileSize: nil, modifiedAt: nil)),
            RepresentationInput(uti: "public.file-url", role: .alternate, payload: .fileURL("file:///tmp/y", fileSize: nil, modifiedAt: nil)),
        ], to: pasteboard)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        #expect(urls?.map(\.path) == ["/tmp/x", "/tmp/y"])
    }
}

