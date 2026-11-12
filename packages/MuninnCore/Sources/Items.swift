import Foundation

// v2 data model (design §4.3). These types carry no I/O; the store and search
// modules produce and consume them.

/// What an item primarily is, derived from its primary representation's UTI.
public enum ItemKind: String, Codable, Sendable, CaseIterable {
    case text
    case richText = "rich_text"
    case html
    case image
    case pdf
    case file
    case other

    /// The UTI that a `--type <kind>` filter matches by conformance.
    public var conformanceUTI: String? {
        switch self {
        case .text: "public.plain-text"
        case .richText: "public.rtf"
        case .html: "public.html"
        case .image: "public.image"
        case .pdf: "com.adobe.pdf"
        case .file: "public.file-url"
        case .other: nil
        }
    }
}

/// How sure we are about which app a capture came from (§4.14).
public enum SourceConfidence: String, Codable, Sendable {
    /// `org.nspasteboard.source` named the app.
    case high
    /// Frontmost-app guess only.
    case low
    /// Nothing known (e.g. migrated v1 rows, Universal Clipboard).
    case unknown
    /// Muninn's own pasteboard write (§4.8).
    case muninn
}

/// Why a representation's bytes weren't stored.
public enum OmitReason: String, Codable, Sendable {
    case size
    case timeout
    case disk
}

public enum RepresentationRole: String, Codable, Sendable {
    case primary
    case alternate
}

// MARK: - Capture input

public struct SourceApp: Codable, Sendable, Equatable {
    public let bundleID: String?
    public let name: String?
    public let confidence: SourceConfidence

    public init(bundleID: String?, name: String?, confidence: SourceConfidence) {
        self.bundleID = bundleID
        self.name = name
        self.confidence = confidence
    }

    public static let unknown = SourceApp(bundleID: nil, name: nil, confidence: .unknown)
}

public enum RepresentationPayload: Sendable, Equatable {
    /// Text-like content stored in `representations.text`.
    case text(String)
    /// Binary content stored as a chunked asset.
    case data(Data)
    /// A file reference; the file's contents are never copied (§4.3).
    case fileURL(String, fileSize: Int64?, modifiedAt: Date?)
    /// Not stored; the reason is recorded.
    case omitted(OmitReason)
}

public struct RepresentationInput: Sendable, Equatable {
    public let uti: String
    public let role: RepresentationRole
    public let payload: RepresentationPayload

    public init(uti: String, role: RepresentationRole, payload: RepresentationPayload) {
        self.uti = uti
        self.role = role
        self.payload = payload
    }
}

/// One observed pasteboard change that passed the capture policy.
public struct CaptureInput: Sendable, Equatable {
    public let capturedAt: Date
    public let source: SourceApp
    public let changeCount: Int?
    /// Every type the pasteboard offered, kept or not.
    public let availableTypes: [String]
    /// Exactly one must have role `.primary`.
    public let representations: [RepresentationInput]

    public init(
        capturedAt: Date,
        source: SourceApp,
        changeCount: Int?,
        availableTypes: [String],
        representations: [RepresentationInput]
    ) {
        self.capturedAt = capturedAt
        self.source = source
        self.changeCount = changeCount
        self.availableTypes = availableTypes
        self.representations = representations
    }
}

public enum CaptureOutcome: Sendable, Equatable {
    case created(itemID: Int64, eventID: Int64)
    case deduplicated(itemID: Int64, eventID: Int64)

    public var itemID: Int64 {
        switch self {
        case .created(let id, _), .deduplicated(let id, _): id
        }
    }
}

// MARK: - Read models

public struct ItemSummary: Codable, Sendable, Equatable {
    public let id: Int64
    public let kind: ItemKind
    /// Size-capped (`MuninnLimits.previewCharacters`); never the full content.
    public let preview: String?
    /// Size of the primary representation, when known.
    public let byteSize: Int64?
    public let firstCapturedAt: Date
    public let lastCapturedAt: Date
    public let captureCount: Int
    public let isPinned: Bool
    public let isProtected: Bool
    /// Source of the most recent capture.
    public let sourceBundleID: String?
    public let sourceAppName: String?

    public init(
        id: Int64, kind: ItemKind, preview: String?, byteSize: Int64?,
        firstCapturedAt: Date, lastCapturedAt: Date, captureCount: Int,
        isPinned: Bool, isProtected: Bool, sourceBundleID: String?, sourceAppName: String?
    ) {
        self.id = id
        self.kind = kind
        self.preview = preview
        self.byteSize = byteSize
        self.firstCapturedAt = firstCapturedAt
        self.lastCapturedAt = lastCapturedAt
        self.captureCount = captureCount
        self.isPinned = isPinned
        self.isProtected = isProtected
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
    }
}

public struct RepresentationInfo: Codable, Sendable, Equatable {
    public let id: Int64
    public let uti: String
    public let role: RepresentationRole
    public let byteSize: Int64?
    public let omitted: OmitReason?
    public let assetID: Int64?
    public let url: String?

    public init(
        id: Int64, uti: String, role: RepresentationRole, byteSize: Int64?,
        omitted: OmitReason?, assetID: Int64?, url: String?
    ) {
        self.id = id
        self.uti = uti
        self.role = role
        self.byteSize = byteSize
        self.omitted = omitted
        self.assetID = assetID
        self.url = url
    }
}

public struct CaptureEventInfo: Codable, Sendable, Equatable {
    public let id: Int64
    public let capturedAt: Date
    public let source: SourceApp
    public let changeCount: Int?
    public let availableTypes: [String]

    public init(id: Int64, capturedAt: Date, source: SourceApp, changeCount: Int?, availableTypes: [String]) {
        self.id = id
        self.capturedAt = capturedAt
        self.source = source
        self.changeCount = changeCount
        self.availableTypes = availableTypes
    }
}

public struct ItemDetail: Codable, Sendable, Equatable {
    public let summary: ItemSummary
    public let representations: [RepresentationInfo]
    /// Full plain text, if the item has a stored plain-text representation.
    public let text: String?

    public init(summary: ItemSummary, representations: [RepresentationInfo], text: String?) {
        self.summary = summary
        self.representations = representations
        self.text = text
    }
}

public struct ItemPage: Codable, Sendable, Equatable {
    public let items: [ItemSummary]
    public let total: Int
    public let hasMore: Bool

    public init(items: [ItemSummary], total: Int, hasMore: Bool) {
        self.items = items
        self.total = total
        self.hasMore = hasMore
    }
}

// MARK: - Search

public struct SearchRequest: Codable, Sendable, Equatable {
    /// Free text; nil or blank means filters only, ordered by recency.
    public var query: String?
    /// Bundle ID or app name of any capture.
    public var app: String?
    /// An `ItemKind` raw value or a UTI, matched by conformance.
    public var type: String?
    public var pinned: Bool?
    public var since: Date?
    public var until: Date?
    /// nil returns everything.
    public var limit: Int?
    /// The CLI excludes protected items from every result (§4.12).
    public var excludeProtected: Bool

    public init(
        query: String? = nil, app: String? = nil, type: String? = nil, pinned: Bool? = nil,
        since: Date? = nil, until: Date? = nil, limit: Int? = MuninnLimits.defaultResultLimit,
        excludeProtected: Bool = true
    ) {
        self.query = query
        self.app = app
        self.type = type
        self.pinned = pinned
        self.since = since
        self.until = until
        self.limit = limit
        self.excludeProtected = excludeProtected
    }
}
