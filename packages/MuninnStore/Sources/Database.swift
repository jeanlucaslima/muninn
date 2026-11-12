import Foundation
import CSQLite

// C-interop layer for SQLite (design §4.2, convention 5).
//
// `Database` is deliberately not Sendable: each connection is owned by exactly
// one actor (`StoreWriter` or a `StoreReader`), which serializes all access.
// The only escape hatch is `InterruptHandle`, below.

public enum SQLValue: Sendable, Equatable {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null
}

public struct DatabaseError: Error, Sendable, CustomStringConvertible {
    public let code: Int32
    public let message: String

    public var isInterrupt: Bool { code == SQLITE_INTERRUPT }
    public var description: String { "SQLite error \(code): \(message)" }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class Database {
    private let handle: OpaquePointer

    public init(path: String, readOnly: Bool) throws {
        var db: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE))
            | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close_v2(db)
            throw DatabaseError(code: rc, message: message)
        }
        handle = db
        sqlite3_extended_result_codes(db, 0)
        sqlite3_busy_timeout(db, 5_000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    public var interruptHandle: InterruptHandle { InterruptHandle(handle: handle) }
    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    public var changes: Int { Int(sqlite3_changes(handle)) }

    /// Runs one or more statements with no parameters.
    public func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorMessage)
            throw DatabaseError(code: rc, message: message)
        }
    }

    public func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw DatabaseError(code: rc, message: lastErrorMessage)
        }
        return Statement(stmt: stmt, db: self)
    }

    /// Runs a statement to completion, ignoring rows.
    public func run(_ sql: String, _ args: [SQLValue] = []) throws {
        let stmt = try prepare(sql)
        try stmt.bind(args)
        while try stmt.step() {}
    }

    public func query<T>(_ sql: String, _ args: [SQLValue] = [], _ map: (Row) throws -> T) throws -> [T] {
        let stmt = try prepare(sql)
        try stmt.bind(args)
        var out: [T] = []
        while try stmt.step() {
            out.append(try map(Row(stmt: stmt)))
        }
        return out
    }

    public func queryOne<T>(_ sql: String, _ args: [SQLValue] = [], _ map: (Row) throws -> T) throws -> T? {
        let stmt = try prepare(sql)
        try stmt.bind(args)
        guard try stmt.step() else { return nil }
        return try map(Row(stmt: stmt))
    }

    /// `BEGIN IMMEDIATE` … `COMMIT`, rolling back on any error.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// A read transaction: every statement inside sees one WAL snapshot.
    public func readTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN DEFERRED")
        defer { try? execute("COMMIT") }
        return try body()
    }

    fileprivate var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }
    fileprivate var lastErrorCode: Int32 { sqlite3_errcode(handle) }

    // MARK: - Statement

    public final class Statement {
        private let stmt: OpaquePointer
        private let db: Database

        fileprivate init(stmt: OpaquePointer, db: Database) {
            self.stmt = stmt
            self.db = db
        }

        deinit {
            sqlite3_finalize(stmt)
        }

        public func bind(_ args: [SQLValue]) throws {
            for (offset, value) in args.enumerated() {
                let index = Int32(offset + 1)
                let rc: Int32
                switch value {
                case .int(let v): rc = sqlite3_bind_int64(stmt, index, v)
                case .double(let v): rc = sqlite3_bind_double(stmt, index, v)
                case .text(let v): rc = sqlite3_bind_text(stmt, index, v, -1, transient)
                case .blob(let v):
                    rc = v.withUnsafeBytes { buffer in
                        // A zero-length blob still needs a non-NULL pointer to bind as a blob.
                        sqlite3_bind_blob(stmt, index, buffer.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(v.count), transient)
                    }
                case .null: rc = sqlite3_bind_null(stmt, index)
                }
                guard rc == SQLITE_OK else { throw DatabaseError(code: rc, message: db.lastErrorMessage) }
            }
        }

        /// Returns true when a row is available.
        public func step() throws -> Bool {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            case let rc: throw DatabaseError(code: rc, message: db.lastErrorMessage)
            }
        }

        public func reset() {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }

        /// The row the last successful `step()` produced.
        public var row: Row { Row(stmt: self) }

        fileprivate var raw: OpaquePointer { stmt }
    }

    // MARK: - Row

    public struct Row {
        fileprivate let stmt: Statement

        public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt.raw, i) == SQLITE_NULL }
        public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt.raw, i) }
        public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt.raw, i) }

        public func optionalInt(_ i: Int32) -> Int64? { isNull(i) ? nil : int(i) }

        public func text(_ i: Int32) -> String? {
            guard let ptr = sqlite3_column_text(stmt.raw, i) else { return nil }
            let count = Int(sqlite3_column_bytes(stmt.raw, i))
            return String(decoding: UnsafeBufferPointer(start: ptr, count: count), as: UTF8.self)
        }

        public func blob(_ i: Int32) -> Data? {
            guard !isNull(i) else { return nil }
            let count = Int(sqlite3_column_bytes(stmt.raw, i))
            guard count > 0, let ptr = sqlite3_column_blob(stmt.raw, i) else { return Data() }
            return Data(bytes: ptr, count: count)
        }
    }
}

/// Lets a cancelled task abort the query running on a connection.
///
/// SAFETY: `sqlite3_interrupt` is documented as safe to call from any thread
/// while the connection is open. The handle is only used inside
/// `withTaskCancellationHandler` around a call on the actor that owns the
/// connection, so the connection outlives every use.
public struct InterruptHandle: @unchecked Sendable {
    fileprivate let handle: OpaquePointer

    public func interrupt() {
        sqlite3_interrupt(handle)
    }
}
