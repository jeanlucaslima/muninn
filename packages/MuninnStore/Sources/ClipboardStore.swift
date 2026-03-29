import Foundation
import CryptoKit
import MuninnCore

public enum InsertResult: Sendable {
    case stored(ClipboardEntry)
    case deduplicated
    case skippedTooLarge(contentSize: Int, maxSize: Int)
}

public final class ClipboardStore: @unchecked Sendable {
    private let connection: SQLiteConnection
    private let lock = NSLock()
    public let maxContentSize = 1_000_000 // 1 MB

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
    /// Returns the result indicating what happened.
    @discardableResult
    public func insert(_ content: String) throws -> InsertResult {
        let contentSize = content.utf8.count
        guard contentSize <= maxContentSize else {
            return .skippedTooLarge(contentSize: contentSize, maxSize: maxContentSize)
        }

        let hash = sha256(content)

        lock.lock()
        defer { lock.unlock() }

        // Check if the last entry has the same hash
        let checkStmt = try connection.prepare(
            "SELECT content_hash FROM clipboard_entries ORDER BY id DESC LIMIT 1")
        if try checkStmt.step() {
            let lastHash = checkStmt.columnString(0)
            if lastHash == hash {
                return .deduplicated
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
        guard try readStmt.step() else { return .deduplicated }

        return .stored(entryFromStatement(readStmt))
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

    // MARK: - Get

    public func get(id: Int64) throws -> ClipboardEntry? {
        lock.lock()
        defer { lock.unlock() }

        let stmt = try connection.prepare(
            "SELECT id, content, content_hash, created_at, is_pinned FROM clipboard_entries WHERE id = ?1")
        stmt.bind(1, id)
        guard try stmt.step() else { return nil }
        return entryFromStatement(stmt)
    }

    // MARK: - Search

    public func search(query: String, limit: Int = 20) throws -> [ClipboardEntry] {
        lock.lock()
        defer { lock.unlock() }

        let escaped = escapeLikePattern(query)
        let stmt = try connection.prepare(
            "SELECT id, content, content_hash, created_at, is_pinned FROM clipboard_entries WHERE content LIKE ?1 ESCAPE '\\' ORDER BY id DESC LIMIT ?2")
        stmt.bind(1, "%\(escaped)%")
        stmt.bind(2, Int64(limit))

        var entries: [ClipboardEntry] = []
        while try stmt.step() {
            entries.append(entryFromStatement(stmt))
        }

        return entries
    }

    // MARK: - Delete

    @discardableResult
    public func delete(id: Int64) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let stmt = try connection.prepare("DELETE FROM clipboard_entries WHERE id = ?1")
        stmt.bind(1, id)
        try stmt.step()
        return connection.changes() > 0
    }

    // MARK: - Pin / Unpin

    @discardableResult
    public func pin(id: Int64) throws -> Bool {
        try setPinned(id: id, pinned: true)
    }

    @discardableResult
    public func unpin(id: Int64) throws -> Bool {
        try setPinned(id: id, pinned: false)
    }

    private func setPinned(id: Int64, pinned: Bool) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let stmt = try connection.prepare("UPDATE clipboard_entries SET is_pinned = ?1 WHERE id = ?2")
        stmt.bind(1, Int32(pinned ? 1 : 0))
        stmt.bind(2, id)
        try stmt.step()
        return connection.changes() > 0
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

    private func escapeLikePattern(_ pattern: String) -> String {
        pattern
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

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
