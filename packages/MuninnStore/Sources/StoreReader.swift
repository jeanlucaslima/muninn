import Foundation
import MuninnCore

/// One read-only connection (design §4.2). WAL lets readers run while the
/// writer commits, so a slow search never blocks capture.
public actor StoreReader {
    private let db: Database

    /// The database must already exist (a `StoreWriter` creates it).
    public init(path: String) throws {
        let db = try Database(path: path, readOnly: true)
        try db.execute("PRAGMA query_only = ON; PRAGMA temp_store = MEMORY;")
        self.db = db
    }

    /// Runs `body` on this connection. Cancelling the calling task aborts the
    /// running statement and throws `CancellationError`.
    public func read<T: Sendable>(_ body: @Sendable (Database) throws -> T) async throws -> T {
        try Task.checkCancellation()
        let interrupt = db.interruptHandle
        do {
            return try await withTaskCancellationHandler {
                try body(db)
            } onCancel: {
                interrupt.interrupt()
            }
        } catch let error as DatabaseError where error.isInterrupt {
            throw CancellationError()
        }
    }
}

/// A small fixed set of readers; requests spread across them.
public struct ReaderPool: Sendable {
    private let readers: [StoreReader]

    public init(path: String, size: Int = 2) throws {
        precondition(size > 0)
        readers = try (0..<size).map { _ in try StoreReader(path: path) }
    }

    public func read<T: Sendable>(_ body: @Sendable (Database) throws -> T) async throws -> T {
        // Random choice needs no shared state; with 2–3 readers it spreads load well enough.
        try await readers.randomElement()!.read(body)
    }
}

public enum PayloadResult: Sendable, Equatable {
    case chunk(PayloadChunk)
    /// No representation matches the selector (or the pinned id).
    case noSuchRepresentation
    /// The matching representation's bytes weren't stored.
    case omitted(OmitReason)
    case chunkOutOfRange
}

/// Item reads shared by search, the CLI and the panel. All take a connection
/// so callers can group them in one read transaction.
public enum ItemQueries {
    /// Summaries for `ids`, in the same order. Missing ids are skipped.
    public static func summaries(_ db: Database, ids: [Int64]) throws -> [ItemSummary] {
        var byID: [Int64: ItemSummary] = [:]
        let batchSize = 500
        var start = 0
        while start < ids.count {
            let batch = Array(ids[start..<min(start + batchSize, ids.count)])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let rows = try db.query(summarySQL + " WHERE ci.id IN (\(placeholders))", batch.map(SQLValue.int), summary)
            for row in rows { byID[row.id] = row }
            start += batchSize
        }
        return ids.compactMap { byID[$0] }
    }

    public static func detail(_ db: Database, id: Int64) throws -> ItemDetail? {
        guard let summary = try db.queryOne(summarySQL + " WHERE ci.id = ?", [.int(id)], summary) else {
            return nil
        }
        let reps = try db.query("""
            SELECT id, uti, role, byte_size, omitted, asset_id, url
            FROM representations WHERE content_item_id = ? ORDER BY id
            """, [.int(id)]) { row in
            RepresentationInfo(
                id: row.int(0),
                uti: row.text(1) ?? "",
                role: RepresentationRole(rawValue: row.text(2) ?? "") ?? .alternate,
                byteSize: row.optionalInt(3),
                omitted: row.text(4).flatMap(OmitReason.init(rawValue:)),
                assetID: row.optionalInt(5),
                url: row.text(6)
            )
        }
        let text = try db.queryOne("""
            SELECT text FROM representations
            WHERE content_item_id = ? AND text IS NOT NULL AND uti IN (\(Schema.plainTextUTIList))
            ORDER BY id LIMIT 1
            """, [.int(id)]) { $0.text(0) } ?? nil
        return ItemDetail(summary: summary, representations: reps, text: text)
    }

    /// The item's capture events, oldest first; nil if the item doesn't exist.
    public static func history(_ db: Database, id: Int64) throws -> [CaptureEventInfo]? {
        guard try db.queryOne("SELECT 1 FROM content_items WHERE id = ?", [.int(id)], { _ in true }) != nil else {
            return nil
        }
        return try db.query("""
            SELECT id, captured_at, source_bundle_id, source_app_name, source_confidence, change_count, available_types
            FROM capture_events WHERE content_item_id = ? ORDER BY captured_at, id
            """, [.int(id)]) { row in
            let types = (row.text(6)?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            return CaptureEventInfo(
                id: row.int(0),
                capturedAt: Timestamp.date(row.int(1)),
                source: SourceApp(
                    bundleID: row.text(2), name: row.text(3),
                    confidence: SourceConfidence(rawValue: row.text(4) ?? "") ?? .unknown),
                changeCount: row.optionalInt(5).map(Int.init),
                availableTypes: types
            )
        }
    }

    public static func itemCount(_ db: Database) throws -> Int {
        Int(try db.queryOne("SELECT COUNT(*) FROM content_items") { $0.int(0) } ?? 0)
    }

    /// The item's stored representations as payloads, for putting back on the
    /// pasteboard. Omitted ones are skipped; nil if the item doesn't exist.
    /// Assets are read whole: they're bounded by the capture limits.
    public static func restorable(_ db: Database, id: Int64) throws -> [RepresentationInput]? {
        guard try db.queryOne("SELECT 1 FROM content_items WHERE id = ?", [.int(id)], { _ in true }) != nil else {
            return nil
        }
        struct Row { let uti: String; let role: RepresentationRole; let text: String?; let assetID: Int64?; let url: String? }
        let rows = try db.query("""
            SELECT uti, role, text, asset_id, url FROM representations
            WHERE content_item_id = ? AND omitted IS NULL ORDER BY id
            """, [.int(id)]) { row in
            Row(uti: row.text(0) ?? "", role: RepresentationRole(rawValue: row.text(1) ?? "") ?? .alternate,
                text: row.text(2), assetID: row.optionalInt(3), url: row.text(4))
        }
        return try rows.compactMap { row in
            if let text = row.text {
                return RepresentationInput(uti: row.uti, role: row.role, payload: .text(text))
            }
            if let url = row.url {
                return RepresentationInput(uti: row.uti, role: row.role, payload: .fileURL(url, fileSize: nil, modifiedAt: nil))
            }
            if let assetID = row.assetID {
                var data = Data()
                try forEachChunk(db, assetID: assetID) { data.append($0) }
                return RepresentationInput(uti: row.uti, role: row.role, payload: .data(data))
            }
            return nil
        }
    }

    /// Calls `body` with each chunk of an asset in order, so memory stays
    /// bounded by the chunk size. Returns false if the asset doesn't exist.
    @discardableResult
    public static func forEachChunk(_ db: Database, assetID: Int64, _ body: (Data) throws -> Void) throws -> Bool {
        guard try db.queryOne("SELECT 1 FROM assets WHERE id = ?", [.int(assetID)], { _ in true }) != nil else {
            return false
        }
        let stmt = try db.prepare("SELECT data FROM asset_chunks WHERE asset_id = ? ORDER BY idx")
        try stmt.bind([.int(assetID)])
        while try stmt.step() {
            try body(stmt.row.blob(0) ?? Data())
        }
        return true
    }

    // MARK: - Payload (paste)

    /// One chunk of one representation's bytes (§4.11 `paste`). `selector` is
    /// nil for the primary, a kind, or a UTI; `representationID`, when given,
    /// pins the representation chosen by an earlier chunk. nil if the item
    /// doesn't exist.
    ///
    /// Text and file references are sliced by `textChunkBytes` straight from
    /// the row; assets go out one stored chunk at a time. Neither loads the
    /// whole value.
    public static func payload(
        _ db: Database, id: Int64, selector: String?, representationID: Int64?, chunk: Int,
        textChunkBytes: Int = MuninnLimits.payloadChunkBytes
    ) throws -> PayloadResult? {
        try db.readTransaction {
            guard try db.queryOne("SELECT 1 FROM content_items WHERE id = ?", [.int(id)], { _ in true }) != nil else {
                return nil
            }
            struct Rep { let id: Int64; let uti: String; let role: String; let hasText: Bool; let assetID: Int64?; let hasURL: Bool; let omitted: String? }
            let reps = try db.query("""
                SELECT id, uti, role, text IS NOT NULL, asset_id, url IS NOT NULL, omitted
                FROM representations WHERE content_item_id = ?
                ORDER BY role = 'primary' DESC, id
                """, [.int(id)]) { row in
                Rep(id: row.int(0), uti: row.text(1) ?? "", role: row.text(2) ?? "", hasText: row.int(3) != 0,
                    assetID: row.optionalInt(4), hasURL: row.int(5) != 0, omitted: row.text(6))
            }

            let matching: [Rep]
            if let representationID {
                matching = reps.filter { $0.id == representationID }
            } else if let selector {
                if let kind = ItemKind(rawValue: selector) {
                    matching = reps.filter { Identity.kind(forUTI: $0.uti) == kind }
                } else {
                    matching = reps.filter { $0.uti == selector }
                }
            } else {
                matching = reps.filter { $0.role == RepresentationRole.primary.rawValue }
            }
            guard !matching.isEmpty else { return .noSuchRepresentation }
            // Prefer stored bytes over an omitted match of the same kind.
            guard let rep = matching.first(where: { $0.omitted == nil }) else {
                return .omitted(OmitReason(rawValue: matching[0].omitted ?? "") ?? .size)
            }
            guard chunk >= 0 else { return .chunkOutOfRange }

            if rep.hasText || rep.hasURL {
                let column = rep.hasText ? "text" : "url"
                let read = try db.readBytes(table: "representations", column: column, rowID: rep.id,
                                            offset: chunk * textChunkBytes, length: textChunkBytes)
                let count = max(1, (read.total + textChunkBytes - 1) / textChunkBytes)
                guard chunk < count else { return .chunkOutOfRange }
                return .chunk(PayloadChunk(id: id, representationID: rep.id, uti: rep.uti, byteSize: Int64(read.total),
                                           chunk: chunk, chunkCount: count, data: read.data))
            }
            if let assetID = rep.assetID {
                guard let (size, count) = try db.queryOne(
                    "SELECT byte_size, (SELECT COUNT(*) FROM asset_chunks WHERE asset_id = assets.id) FROM assets WHERE id = ?",
                    [.int(assetID)], { ($0.int(0), Int($0.int(1))) }) else {
                    return .noSuchRepresentation
                }
                guard chunk < count else { return .chunkOutOfRange }
                let data = try db.queryOne("SELECT data FROM asset_chunks WHERE asset_id = ? AND idx = ?",
                                           [.int(assetID), .int(Int64(chunk))]) { $0.blob(0) ?? Data() } ?? Data()
                return .chunk(PayloadChunk(id: id, representationID: rep.id, uti: rep.uti, byteSize: size,
                                           chunk: chunk, chunkCount: count, data: data))
            }
            return .noSuchRepresentation
        }
    }

    // MARK: - Diagnostics (doctor)

    /// `PRAGMA quick_check` rows; `["ok"]` when sound.
    public static func quickCheck(_ db: Database) throws -> [String] {
        try db.query("PRAGMA quick_check") { $0.text(0) ?? "" }
    }

    /// Items whose search index rows are missing or from an older index version.
    public static func staleIndexCount(_ db: Database) throws -> Int {
        Int(try db.queryOne(
            "SELECT COUNT(*) FROM content_items WHERE indexed_version IS NULL OR indexed_version != ?",
            [.int(Schema.indexVersion)]) { $0.int(0) } ?? 0)
    }

    public static func lastCaptureAt(_ db: Database) throws -> Date? {
        try db.queryOne("SELECT MAX(captured_at) FROM capture_events") { $0.optionalInt(0) }?.map(Timestamp.date)
    }

    // MARK: - Private

    private static let summarySQL = """
        SELECT ci.id, ci.primary_kind,
               (SELECT substr(r.text, 1, \(MuninnLimits.previewCharacters)) FROM representations r
                 WHERE r.content_item_id = ci.id AND r.text IS NOT NULL AND r.uti IN (\(Schema.plainTextUTIList))
                 ORDER BY r.id LIMIT 1),
               (SELECT r.url FROM representations r
                 WHERE r.content_item_id = ci.id AND r.url IS NOT NULL ORDER BY r.id LIMIT 1),
               (SELECT COUNT(*) FROM representations r
                 WHERE r.content_item_id = ci.id AND r.url IS NOT NULL),
               (SELECT r.byte_size FROM representations r
                 WHERE r.content_item_id = ci.id AND r.role = 'primary' LIMIT 1),
               ci.first_captured_at, ci.last_captured_at, ci.capture_count, ci.is_pinned, ci.is_protected,
               e.source_bundle_id, e.source_app_name
        FROM content_items ci
        LEFT JOIN capture_events e ON e.id = (
            SELECT id FROM capture_events WHERE content_item_id = ci.id ORDER BY captured_at DESC, id DESC LIMIT 1)
        """

    private static func summary(_ row: Database.Row) -> ItemSummary {
        var preview = row.text(2)
        if preview == nil, let url = row.text(3) {
            let name = URL(string: url)?.lastPathComponent ?? url
            let others = row.int(4) - 1
            preview = others > 0 ? "\(name) (+\(others) more)" : name
        }
        return ItemSummary(
            id: row.int(0),
            kind: ItemKind(rawValue: row.text(1) ?? "") ?? .other,
            preview: preview,
            byteSize: row.optionalInt(5),
            firstCapturedAt: Timestamp.date(row.int(6)),
            lastCapturedAt: Timestamp.date(row.int(7)),
            captureCount: Int(row.int(8)),
            isPinned: row.int(9) != 0,
            isProtected: row.int(10) != 0,
            sourceBundleID: row.text(11),
            sourceAppName: row.text(12)
        )
    }
}
