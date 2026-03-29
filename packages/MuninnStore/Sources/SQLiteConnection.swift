import Foundation
import CSQLite

public final class SQLiteConnection: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()

    public init(path: String) throws {
        let result = sqlite3_open(path, &db)
        guard result == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw SQLiteError.openFailed(message)
        }
        // Enable WAL mode for better concurrent read performance
        try execute("PRAGMA journal_mode=WAL")
    }

    deinit {
        sqlite3_close(db)
    }

    public func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorMessage)
            throw SQLiteError.executionFailed(message)
        }
    }

    public func prepare(_ sql: String) throws -> Statement {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard result == SQLITE_OK, let statement = stmt else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw SQLiteError.prepareFailed(message)
        }
        return Statement(stmt: statement, connection: self)
    }

    public func lastInsertRowId() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return sqlite3_last_insert_rowid(db)
    }

    public func changes() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return Int(sqlite3_changes(db))
    }

    // MARK: - Statement

    public final class Statement: @unchecked Sendable {
        private let stmt: OpaquePointer
        private unowned let connection: SQLiteConnection

        init(stmt: OpaquePointer, connection: SQLiteConnection) {
            self.stmt = stmt
            self.connection = connection
        }

        deinit {
            sqlite3_finalize(stmt)
        }

        public func bind(_ index: Int32, _ value: String) {
            sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }

        public func bind(_ index: Int32, _ value: Int64) {
            sqlite3_bind_int64(stmt, index, value)
        }

        public func bind(_ index: Int32, _ value: Int32) {
            sqlite3_bind_int(stmt, index, value)
        }

        @discardableResult
        public func step() throws -> Bool {
            connection.lock.lock()
            defer { connection.lock.unlock() }
            let result = sqlite3_step(stmt)
            switch result {
            case SQLITE_ROW:
                return true
            case SQLITE_DONE:
                return false
            default:
                let message = String(cString: sqlite3_errmsg(connection.db))
                throw SQLiteError.stepFailed(message)
            }
        }

        public func columnInt64(_ index: Int32) -> Int64 {
            sqlite3_column_int64(stmt, index)
        }

        public func columnString(_ index: Int32) -> String {
            guard let text = sqlite3_column_text(stmt, index) else { return "" }
            return String(cString: text)
        }

        public func columnInt(_ index: Int32) -> Int32 {
            sqlite3_column_int(stmt, index)
        }

        public func reset() {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
    }
}

public enum SQLiteError: Error, CustomStringConvertible {
    case openFailed(String)
    case executionFailed(String)
    case prepareFailed(String)
    case stepFailed(String)

    public var description: String {
        switch self {
        case .openFailed(let msg): return "SQLite open failed: \(msg)"
        case .executionFailed(let msg): return "SQLite execution failed: \(msg)"
        case .prepareFailed(let msg): return "SQLite prepare failed: \(msg)"
        case .stepFailed(let msg): return "SQLite step failed: \(msg)"
        }
    }
}
