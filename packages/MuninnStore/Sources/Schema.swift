import Foundation
import MuninnCore
import CryptoKit

/// v2 schema (design §4.3). Migrations are ordered, each runs in one
/// transaction and is recorded in `schema_migrations` with a checksum; a
/// recorded checksum that no longer matches the code is a startup error.
///
/// Not yet created: `previews`, `processing_jobs`, `settings`, `audit_log`.
/// They arrive with the features that write them.
enum Schema {
    struct Migration {
        let version: Int
        let name: String
        let sql: String

        var checksum: String {
            SHA256.hash(data: Data(sql.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Bump to rebuild every item's index rows on the next start.
    static let indexVersion: Int64 = 1

    /// Rows per item in `search_index`: rowid = itemID * stride + n.
    static let indexStride = Int64(MuninnLimits.indexRowsPerItem)

    /// Plain-text UTIs: what's indexed and used for previews.
    static let plainTextUTIs = [
        "public.utf8-plain-text",
        "public.plain-text",
        "public.utf16-plain-text",
        "public.utf16-external-plain-text",
    ]

    static var plainTextUTIList: String {
        plainTextUTIs.map { "'\($0)'" }.joined(separator: ",")
    }

    static let migrations: [Migration] = [
        Migration(version: 1, name: "v2 core model", sql: """
            CREATE TABLE content_items (
                id                INTEGER PRIMARY KEY,
                content_hash      TEXT UNIQUE,
                primary_kind      TEXT    NOT NULL,
                first_captured_at INTEGER NOT NULL,
                last_captured_at  INTEGER NOT NULL,
                capture_count     INTEGER NOT NULL DEFAULT 1,
                is_pinned         INTEGER NOT NULL DEFAULT 0,
                is_protected      INTEGER NOT NULL DEFAULT 0,
                indexed_version   INTEGER
            );
            CREATE INDEX content_items_recency ON content_items(last_captured_at DESC, id DESC);
            CREATE INDEX content_items_stale ON content_items(indexed_version);

            CREATE TABLE capture_events (
                id                INTEGER PRIMARY KEY,
                content_item_id   INTEGER NOT NULL REFERENCES content_items(id) ON DELETE CASCADE,
                captured_at       INTEGER NOT NULL,
                source_bundle_id  TEXT,
                source_app_name   TEXT,
                source_confidence TEXT    NOT NULL,
                change_count      INTEGER,
                available_types   TEXT    NOT NULL DEFAULT '[]'
            );
            CREATE INDEX capture_events_item ON capture_events(content_item_id, captured_at);
            CREATE INDEX capture_events_time ON capture_events(captured_at);

            CREATE TABLE assets (
                id         INTEGER PRIMARY KEY,
                sha256     TEXT    NOT NULL UNIQUE,
                byte_size  INTEGER NOT NULL,
                chunk_size INTEGER NOT NULL,
                storage    TEXT    NOT NULL DEFAULT 'inline' CHECK (storage IN ('inline', 'external'))
            );

            CREATE TABLE asset_chunks (
                asset_id INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
                idx      INTEGER NOT NULL,
                data     BLOB    NOT NULL,
                PRIMARY KEY (asset_id, idx)
            ) WITHOUT ROWID;

            CREATE TABLE representations (
                id              INTEGER PRIMARY KEY,
                content_item_id INTEGER NOT NULL REFERENCES content_items(id) ON DELETE CASCADE,
                uti             TEXT    NOT NULL,
                role            TEXT    NOT NULL CHECK (role IN ('primary', 'alternate')),
                text            TEXT,
                asset_id        INTEGER REFERENCES assets(id),
                url             TEXT,
                bookmark        BLOB,
                file_size       INTEGER,
                file_mtime      INTEGER,
                byte_size       INTEGER,
                omitted         TEXT
            );
            CREATE INDEX representations_item ON representations(content_item_id);
            CREATE INDEX representations_asset ON representations(asset_id);
            CREATE INDEX representations_uti ON representations(uti);

            CREATE TABLE extracted_text (
                id                INTEGER PRIMARY KEY,
                content_item_id   INTEGER NOT NULL REFERENCES content_items(id) ON DELETE CASCADE,
                representation_id INTEGER REFERENCES representations(id) ON DELETE CASCADE,
                source            TEXT    NOT NULL CHECK (source IN ('ocr', 'pdf', 'html', 'rtf')),
                text              TEXT    NOT NULL,
                language          TEXT,
                confidence        REAL,
                extractor_version INTEGER NOT NULL
            );
            CREATE INDEX extracted_text_item ON extracted_text(content_item_id);

            CREATE TABLE annotations (
                id               INTEGER PRIMARY KEY,
                content_item_id  INTEGER NOT NULL REFERENCES content_items(id) ON DELETE CASCADE,
                kind             TEXT    NOT NULL,
                value            TEXT    NOT NULL,
                producer_version INTEGER NOT NULL
            );
            CREATE INDEX annotations_item ON annotations(content_item_id);

            CREATE VIRTUAL TABLE search_index USING fts5(
                text,
                tokenize = 'trigram remove_diacritics 1'
            );
            -- Deleted index entries are removed from disk, not just marked (§4.3, physical purge).
            INSERT INTO search_index (search_index, rank) VALUES ('secure-delete', 1);
            """),
    ]

    /// Applies pending migrations; verifies checksums of applied ones.
    static func migrate(_ db: Database) throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version    INTEGER PRIMARY KEY,
                name       TEXT    NOT NULL,
                applied_at INTEGER NOT NULL,
                checksum   TEXT    NOT NULL
            )
            """)

        let applied = try db.query("SELECT version, checksum FROM schema_migrations") { row in
            (row.int(0), row.text(1) ?? "")
        }
        let appliedChecksums = Dictionary(uniqueKeysWithValues: applied)

        for migration in migrations {
            if let recorded = appliedChecksums[Int64(migration.version)] {
                guard recorded == migration.checksum else {
                    throw StoreError.migrationChecksumMismatch(version: migration.version)
                }
                continue
            }
            try db.transaction {
                try db.execute(migration.sql)
                try db.run(
                    "INSERT INTO schema_migrations (version, name, applied_at, checksum) VALUES (?, ?, ?, ?)",
                    [.int(Int64(migration.version)), .text(migration.name),
                     .int(Timestamp.from(Date())), .text(migration.checksum)]
                )
            }
        }

        let known = Set(migrations.map { Int64($0.version) })
        if let unknown = appliedChecksums.keys.first(where: { !known.contains($0) }) {
            throw StoreError.unknownMigration(version: Int(unknown))
        }
    }
}

public enum StoreError: Error, Sendable, Equatable, CustomStringConvertible {
    case migrationChecksumMismatch(version: Int)
    case unknownMigration(version: Int)
    case invalidCapture(String)
    case v1Database(path: String)

    public var description: String {
        switch self {
        case .v1Database(let path):
            "\(path) is a v1 database; it needs migrating, which isn't implemented yet"
        case .migrationChecksumMismatch(let v):
            "migration \(v) was applied with different SQL than this build has"
        case .unknownMigration(let v):
            "database has migration \(v), which this build doesn't know (newer Muninn?)"
        case .invalidCapture(let reason):
            "invalid capture: \(reason)"
        }
    }
}

/// Timestamps are stored as integer milliseconds since 1970 (UTC).
enum Timestamp {
    static func from(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func date(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }
}
