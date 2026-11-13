import Foundation

/// The single in-code source of every limit value (design §4.14).
/// Only the values the v2 engine uses so far live here; the rest arrive with
/// the features that need them.
public enum MuninnLimits {
    /// Default `--limit` for `list` and `search`.
    public static let defaultResultLimit = 20
    /// Characters of text in a list/search `preview`.
    public static let previewCharacters = 200
    /// Bytes per `asset_chunks` row (PROOF-005 decides the final value).
    public static let assetChunkBytes = 256 * 1024
    /// Index rows one item may have (plain text + extracted text sources).
    public static let indexRowsPerItem = 1024

    // Capture (§4.8, §4.14). macOS doesn't expose a representation's size
    // before it's read, so these apply right after each read.

    /// Bytes per representation; larger ones are kept as `omitted: "size"`.
    public static let maxRepresentationBytes = 64 * 1024 * 1024
    /// Bytes per capture across all representations.
    public static let maxCaptureBytes = 128 * 1024 * 1024
    /// File references kept per capture; past it, none are kept.
    public static let maxFileReferences = 500
    /// Observed changes waiting to be persisted; past it, changes aren't read
    /// and count as `droppedBackpressure`.
    public static let maxPendingCaptures = 8
    /// Largest IPC request accepted.
    public static let maxRequestBytes = 1024 * 1024
    /// Largest `payload` chunk of text or a file reference; asset chunks go
    /// out as stored (`assetChunkBytes`).
    public static let payloadChunkBytes = 256 * 1024

    /// Pasteboard polling interval (D6).
    public static let pollInterval: Duration = .milliseconds(500)

    /// Every limit, for `muninn status --limits`. Keep in step with the values above.
    public static let catalog: [LimitInfo] = [
        LimitInfo("defaultResultLimit", Int64(defaultResultLimit), "items"),
        LimitInfo("previewCharacters", Int64(previewCharacters), "characters"),
        LimitInfo("assetChunkBytes", Int64(assetChunkBytes), "bytes"),
        LimitInfo("indexRowsPerItem", Int64(indexRowsPerItem), "rows"),
        LimitInfo("maxRepresentationBytes", Int64(maxRepresentationBytes), "bytes"),
        LimitInfo("maxCaptureBytes", Int64(maxCaptureBytes), "bytes"),
        LimitInfo("maxFileReferences", Int64(maxFileReferences), "files"),
        LimitInfo("maxPendingCaptures", Int64(maxPendingCaptures), "captures"),
        LimitInfo("maxRequestBytes", Int64(maxRequestBytes), "bytes"),
        LimitInfo("payloadChunkBytes", Int64(payloadChunkBytes), "bytes"),
        LimitInfo("pollInterval", pollInterval.components.seconds * 1000
            + pollInterval.components.attoseconds / 1_000_000_000_000_000, "milliseconds"),
    ]
}

public struct LimitInfo: Codable, Sendable, Equatable {
    public let name: String
    public let value: Int64
    public let unit: String

    public init(_ name: String, _ value: Int64, _ unit: String) {
        self.name = name
        self.value = value
        self.unit = unit
    }
}
