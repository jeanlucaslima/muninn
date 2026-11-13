import Foundation
import MuninnCore
import CryptoKit
import UniformTypeIdentifiers

/// Owns the single write connection (design §4.2). Every write to history
/// goes through here.
public actor StoreWriter {
    private let db: Database
    private let chunkSize: Int

    /// Opens (creating if needed) the v2 database at `path`, applies
    /// migrations, and re-indexes items whose index rows are stale (§4.8).
    public init(path: String, chunkSize: Int = MuninnLimits.assetChunkBytes) throws {
        precondition(chunkSize > 0)
        let db = try Database(path: path, readOnly: false)
        // A v1 database is migrated (§5), never opened as v2: refuse before
        // changing anything, rather than add v2 tables next to v1 history.
        if try db.queryOne("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'clipboard_entries'", [], { _ in true }) != nil {
            throw StoreError.v1Database(path: path)
        }
        try db.execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA foreign_keys = ON;
            PRAGMA secure_delete = ON;
            PRAGMA temp_store = MEMORY;
            """)
        try Schema.migrate(db)
        try Indexer.reindexStale(db)
        self.db = db
        self.chunkSize = chunkSize
    }

    // MARK: - Capture

    /// Persists one capture in one transaction, then runs the index step (D30).
    @discardableResult
    public func capture(_ input: CaptureInput) throws -> CaptureOutcome {
        let primaries = input.representations.filter { $0.role == .primary }
        guard primaries.count == 1 else {
            throw StoreError.invalidCapture("expected exactly one primary representation, got \(primaries.count)")
        }
        let primary = primaries[0]
        let identity = Identity.hash(of: input)
        let at = Timestamp.from(input.capturedAt)

        let outcome: CaptureOutcome = try db.transaction {
            if let identity,
               let existing = try db.queryOne(
                   "SELECT id FROM content_items WHERE content_hash = ?", [.text(identity)], { $0.int(0) }) {
                let eventID = try insertEvent(input, itemID: existing)
                try db.run("""
                    UPDATE content_items
                    SET last_captured_at = MAX(last_captured_at, ?), capture_count = capture_count + 1
                    WHERE id = ?
                    """, [.int(at), .int(existing)])

                // A later capture may add representations the item doesn't have yet.
                let known = Set(try db.query(
                    "SELECT uti FROM representations WHERE content_item_id = ?", [.int(existing)]) { $0.text(0) ?? "" })
                var addedText = false
                for rep in input.representations where !known.contains(rep.uti) {
                    if case .omitted = rep.payload { continue }
                    try insertRepresentation(rep, role: .alternate, itemID: existing)
                    if Schema.plainTextUTIs.contains(rep.uti) { addedText = true }
                }
                if addedText {
                    try db.run("UPDATE content_items SET indexed_version = NULL WHERE id = ?", [.int(existing)])
                }
                return .deduplicated(itemID: existing, eventID: eventID)
            }

            try db.run("""
                INSERT INTO content_items (content_hash, primary_kind, first_captured_at, last_captured_at)
                VALUES (?, ?, ?, ?)
                """, [identity.map(SQLValue.text) ?? .null, .text(Identity.kind(forUTI: primary.uti).rawValue),
                      .int(at), .int(at)])
            let itemID = db.lastInsertRowID
            for rep in input.representations {
                try insertRepresentation(rep, role: rep.role, itemID: itemID)
            }
            let eventID = try insertEvent(input, itemID: itemID)
            return .created(itemID: itemID, eventID: eventID)
        }

        // Committed. If indexing fails, the item stays stale and is
        // re-indexed on the next start (§4.8, idempotency rule 4).
        try? Indexer.indexIfStale(db, itemID: outcome.itemID)
        return outcome
    }

    /// Muninn wrote this item to the pasteboard itself: record exactly one
    /// event with source `muninn` and read nothing (§4.8). Returns nil if the
    /// item no longer exists.
    @discardableResult
    public func recordSelfCopy(itemID: Int64, at date: Date, changeCount: Int?) throws -> Int64? {
        try db.transaction {
            guard try db.queryOne("SELECT 1 FROM content_items WHERE id = ?", [.int(itemID)], { _ in true }) != nil else {
                return nil
            }
            let at = Timestamp.from(date)
            try db.run("""
                INSERT INTO capture_events (content_item_id, captured_at, source_bundle_id, source_app_name,
                                            source_confidence, change_count, available_types)
                VALUES (?, ?, NULL, 'Muninn', 'muninn', ?, '[]')
                """, [.int(itemID), .int(at), changeCount.map { .int(Int64($0)) } ?? .null])
            let eventID = db.lastInsertRowID
            try db.run("""
                UPDATE content_items
                SET last_captured_at = MAX(last_captured_at, ?), capture_count = capture_count + 1
                WHERE id = ?
                """, [.int(at), .int(itemID)])
            return eventID
        }
    }

    // MARK: - Item changes

    @discardableResult
    public func setPinned(_ itemID: Int64, _ pinned: Bool) throws -> Bool {
        try db.run("UPDATE content_items SET is_pinned = ? WHERE id = ?", [.int(pinned ? 1 : 0), .int(itemID)])
        return db.changes > 0
    }

    @discardableResult
    public func setProtected(_ itemID: Int64, _ protected: Bool) throws -> Bool {
        try db.run("UPDATE content_items SET is_protected = ? WHERE id = ?", [.int(protected ? 1 : 0), .int(itemID)])
        return db.changes > 0
    }

    /// Removes the item, its events, representations, derived rows, index
    /// rows and any asset left unreferenced, in one transaction (§4.3), then
    /// checkpoints so deleted pages leave the WAL.
    @discardableResult
    public func delete(_ itemID: Int64) throws -> Bool {
        let deleted: Bool = try db.transaction {
            let assetIDs = try db.query(
                "SELECT DISTINCT asset_id FROM representations WHERE content_item_id = ? AND asset_id IS NOT NULL",
                [.int(itemID)]) { $0.int(0) }
            try Indexer.deleteRows(db, itemID: itemID)
            try db.run("DELETE FROM content_items WHERE id = ?", [.int(itemID)])
            guard db.changes > 0 else { return false }
            for assetID in assetIDs {
                try db.run(
                    "DELETE FROM assets WHERE id = ? AND NOT EXISTS (SELECT 1 FROM representations WHERE asset_id = ?)",
                    [.int(assetID), .int(assetID)])
            }
            return true
        }
        if deleted {
            try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }
        return deleted
    }

    // MARK: - Diagnostics

    /// Runs FTS5 `integrity-check` on the search index: nil when it passes,
    /// the error otherwise. It needs the write connection (it's an INSERT).
    public func searchIndexError() -> String? {
        do {
            try db.run("INSERT INTO search_index (search_index, rank) VALUES ('integrity-check', 1)")
            return nil
        } catch {
            return "\(error)"
        }
    }

    // MARK: - Private

    private func insertEvent(_ input: CaptureInput, itemID: Int64) throws -> Int64 {
        let types = String(decoding: try JSONEncoder().encode(input.availableTypes), as: UTF8.self)
        try db.run("""
            INSERT INTO capture_events (content_item_id, captured_at, source_bundle_id, source_app_name,
                                        source_confidence, change_count, available_types)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, [
                .int(itemID), .int(Timestamp.from(input.capturedAt)),
                input.source.bundleID.map(SQLValue.text) ?? .null,
                input.source.name.map(SQLValue.text) ?? .null,
                .text(input.source.confidence.rawValue),
                input.changeCount.map { .int(Int64($0)) } ?? .null,
                .text(types),
            ])
        return db.lastInsertRowID
    }

    private func insertRepresentation(_ rep: RepresentationInput, role: RepresentationRole, itemID: Int64) throws {
        var text: SQLValue = .null, assetID: SQLValue = .null, url: SQLValue = .null
        var fileSize: SQLValue = .null, fileMtime: SQLValue = .null
        var byteSize: SQLValue = .null, omitted: SQLValue = .null

        switch rep.payload {
        case .text(let value):
            text = .text(value)
            byteSize = .int(Int64(value.utf8.count))
        case .data(let data):
            assetID = .int(try storeAsset(data))
            byteSize = .int(Int64(data.count))
        case .fileURL(let value, let size, let modified):
            url = .text(value)
            fileSize = size.map(SQLValue.int) ?? .null
            fileMtime = modified.map { .int(Timestamp.from($0)) } ?? .null
        case .omitted(let reason):
            omitted = .text(reason.rawValue)
        }

        try db.run("""
            INSERT INTO representations (content_item_id, uti, role, text, asset_id, url,
                                         file_size, file_mtime, byte_size, omitted)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.int(itemID), .text(rep.uti), .text(role.rawValue), text, assetID, url,
                  fileSize, fileMtime, byteSize, omitted])
    }

    /// Stores bytes as a chunked asset, deduplicated by SHA-256.
    private func storeAsset(_ data: Data) throws -> Int64 {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let existing = try db.queryOne("SELECT id FROM assets WHERE sha256 = ?", [.text(digest)], { $0.int(0) }) {
            return existing
        }
        try db.run("INSERT INTO assets (sha256, byte_size, chunk_size) VALUES (?, ?, ?)",
                   [.text(digest), .int(Int64(data.count)), .int(Int64(chunkSize))])
        let assetID = db.lastInsertRowID

        let insert = try db.prepare("INSERT INTO asset_chunks (asset_id, idx, data) VALUES (?, ?, ?)")
        var index: Int64 = 0
        var offset = data.startIndex
        repeat {
            let end = data.index(offset, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex
            insert.reset()
            try insert.bind([.int(assetID), .int(index), .blob(Data(data[offset..<end]))])
            while try insert.step() {}
            index += 1
            offset = end
        } while offset < data.endIndex
        return assetID
    }
}

// MARK: - Identity (§4.3)

enum Identity {
    /// nil means "never deduplicate": the primary representation was omitted
    /// or there's nothing hashable.
    static func hash(of input: CaptureInput) -> String? {
        // Text items: the normalized plain-text representation, whatever else came with it.
        for rep in input.representations where Schema.plainTextUTIs.contains(rep.uti) {
            if case .text(let value) = rep.payload {
                return digest("text\u{0}" + normalize(value))
            }
        }
        guard let primary = input.representations.first(where: { $0.role == .primary }) else { return nil }
        switch primary.payload {
        case .data(let data):
            var hasher = SHA256()
            hasher.update(data: Data("data\u{0}".utf8))
            hasher.update(data: data)
            return hex(hasher.finalize())
        case .fileURL:
            let urls = input.representations.compactMap { rep -> String? in
                if case .fileURL(let url, _, _) = rep.payload { return url }
                return nil
            }
            return digest("files\u{0}" + urls.joined(separator: "\n"))
        case .text(let value):
            // A text-like primary that isn't plain text (e.g. HTML with no plain alternative).
            return digest("\(primary.uti)\u{0}" + value)
        case .omitted:
            return nil
        }
    }

    /// Unicode NFC and LF line endings. Whitespace is otherwise kept: it can matter in code.
    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func kind(forUTI uti: String) -> ItemKind {
        guard let type = UTType(uti) else { return .other }
        if type.conforms(to: .fileURL) { return .file }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .html) { return .html }
        if type.conforms(to: .rtf) || type.conforms(to: .rtfd) || type.conforms(to: .flatRTFD) { return .richText }
        if type.conforms(to: .plainText) { return .text }
        return .other
    }

    private static func digest(_ string: String) -> String {
        hex(SHA256.hash(data: Data(string.utf8)))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Index step (§4.7, §4.8)

enum Indexer {
    /// Rebuilds one item's rows in `search_index` and marks it current.
    static func index(_ db: Database, itemID: Int64) throws {
        try db.transaction {
            try deleteRows(db, itemID: itemID)
            let texts = try db.query("""
                SELECT text FROM representations
                WHERE content_item_id = ? AND text IS NOT NULL AND uti IN (\(Schema.plainTextUTIList))
                ORDER BY id
                """, [.int(itemID)]) { $0.text(0) ?? "" }
                + db.query("SELECT text FROM extracted_text WHERE content_item_id = ? ORDER BY id",
                           [.int(itemID)]) { $0.text(0) ?? "" }

            var seen = Set<String>()
            let unique = texts.filter { !$0.isEmpty && seen.insert($0).inserted }
            let insert = try db.prepare("INSERT INTO search_index (rowid, text) VALUES (?, ?)")
            for (n, text) in unique.prefix(Int(Schema.indexStride)).enumerated() {
                insert.reset()
                try insert.bind([.int(itemID * Schema.indexStride + Int64(n)), .text(text)])
                while try insert.step() {}
            }
            try db.run("UPDATE content_items SET indexed_version = ? WHERE id = ?",
                       [.int(Schema.indexVersion), .int(itemID)])
        }
    }

    static func indexIfStale(_ db: Database, itemID: Int64) throws {
        let stale = try db.queryOne(
            "SELECT indexed_version IS NULL OR indexed_version != ? FROM content_items WHERE id = ?",
            [.int(Schema.indexVersion), .int(itemID)]) { $0.int(0) != 0 }
        if stale == true {
            try index(db, itemID: itemID)
        }
    }

    @discardableResult
    static func reindexStale(_ db: Database) throws -> Int {
        let ids = try db.query(
            "SELECT id FROM content_items WHERE indexed_version IS NULL OR indexed_version != ?",
            [.int(Schema.indexVersion)]) { $0.int(0) }
        for id in ids {
            try index(db, itemID: id)
        }
        return ids.count
    }

    static func deleteRows(_ db: Database, itemID: Int64) throws {
        let base = itemID * Schema.indexStride
        try db.run("DELETE FROM search_index WHERE rowid BETWEEN ? AND ?",
                   [.int(base), .int(base + Schema.indexStride - 1)])
    }
}
