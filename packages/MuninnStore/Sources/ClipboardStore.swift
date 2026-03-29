import Foundation
import CryptoKit
import MuninnCore

public final class ClipboardStore: @unchecked Sendable {
    private let connection: SQLiteConnection
    private let lock = NSLock()
    private let maxContentSize = 1_000_000 // 1 MB

    public init(path: String) throws {
        self.connection = try SQLiteConnection(path: path)
        try migrate()
    }

    // MARK: - Migrations

    private func migrate() throws {
        try connection.execute("""
            CREATE TABLE IF NOT EXISTS clipboard_entries (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                content      TEXT    NOT NULL,
                content_hash TEXT    NOT NULL,
                created_at   TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                is_pinned    INTEGER NOT NULL DEFAULT 0
            )
            """)
        try connection.execute(
            "CREATE INDEX IF NOT EXISTS idx_content_hash ON clipboard_entries(content_hash)")
        try connection.execute(
            "CREATE INDEX IF NOT EXISTS idx_created_at ON clipboard_entries(created_at DESC)")
    }

    // MARK: - Insert

    /// Inserts a clipboard entry if it differs from the most recent one.
    /// Returns the new entry, or nil if deduplicated or content too large.
    @discardableResult
    public func insert(_ content: String) throws -> ClipboardEntry? {
        guard content.utf8.count <= maxContentSize else { return nil }

        let hash = sha256(content)

        lock.lock()
        defer { lock.unlock() }

        // Check if the last entry has the same hash
        let checkStmt = try connection.prepare(
            "SELECT content_hash FROM clipboard_entries ORDER BY id DESC LIMIT 1")
        if try checkStmt.step() {
            let lastHash = checkStmt.columnString(0)
            if lastHash == hash {
                return nil
            }
        }

        // Insert
        let insertStmt = try connection.prepare(
            "INSERT INTO clipboard_entries (content, content_hash) VALUES (?1, ?2)")
        insertStmt.bind(1, content)
        insertStmt.bind(2, hash)
        try insertStmt.step()

        let rowId = connection.lastInsertRowId()

        // Read back the full row to get the server-generated created_at
        let readStmt = try connection.prepare(
            "SELECT id, content, content_hash, created_at, is_pinned FROM clipboard_entries WHERE id = ?1")
        readStmt.bind(1, rowId)
        guard try readStmt.step() else { return nil }

        return entryFromStatement(readStmt)
    }

    // MARK: - List

    public func list(limit: Int = 20, offset: Int = 0) throws -> (entries: [ClipboardEntry], total: Int) {
        lock.lock()
        defer { lock.unlock() }

        let total = try countUnlocked()

        let stmt = try connection.prepare(
            "SELECT id, content, content_hash, created_at, is_pinned FROM clipboard_entries ORDER BY id DESC LIMIT ?1 OFFSET ?2")
        stmt.bind(1, Int64(limit))
        stmt.bind(2, Int64(offset))

        var entries: [ClipboardEntry] = []
        while try stmt.step() {
            entries.append(entryFromStatement(stmt))
        }

        return (entries, total)
    }

    // MARK: - Count

    public func count() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        return try countUnlocked()
    }

    private func countUnlocked() throws -> Int {
        let stmt = try connection.prepare("SELECT COUNT(*) FROM clipboard_entries")
        _ = try stmt.step()
        return Int(stmt.columnInt64(0))
    }

    // MARK: - Helpers

    private func entryFromStatement(_ stmt: SQLiteConnection.Statement) -> ClipboardEntry {
        let id = stmt.columnInt64(0)
        let content = stmt.columnString(1)
        let contentHash = stmt.columnString(2)
        let createdAtStr = stmt.columnString(3)
        let isPinned = stmt.columnInt(4) != 0

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let createdAt = formatter.date(from: createdAtStr) ?? Date()

        return ClipboardEntry(
            id: id,
            content: content,
            contentHash: contentHash,
            createdAt: createdAt,
            isPinned: isPinned
        )
    }

    private func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
