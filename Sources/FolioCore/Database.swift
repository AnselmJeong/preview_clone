import Foundation
import SQLite3

/// A small, dependency-free SQLite wrapper. All access goes through a serial queue,
/// so a `Database` can be shared across threads.
public final class Database: @unchecked Sendable {
    public enum Value: Equatable {
        case null
        case int(Int64)
        case double(Double)
        case text(String)
        case blob(Data)
    }

    public struct DBError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { "SQLite: \(message)" }
    }

    public typealias Row = [String: Value]

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "folio.database")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw DBError(message: msg)
        }
        handle = db
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
    }

    /// In-memory database (tests).
    public convenience init() throws {
        try self.init(path: ":memory:")
    }

    deinit {
        sqlite3_close(handle)
    }

    public func execute(_ sql: String) throws {
        try queue.sync {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
                let msg = err.map { String(cString: $0) } ?? "exec failed"
                sqlite3_free(err)
                throw DBError(message: msg)
            }
        }
    }

    @discardableResult
    public func run(_ sql: String, _ args: [Value?] = []) throws -> Int {
        try queue.sync {
            let stmt = try prepare(sql, args)
            defer { sqlite3_finalize(stmt) }
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw lastError() }
            return Int(sqlite3_changes(handle))
        }
    }

    public func query(_ sql: String, _ args: [Value?] = []) throws -> [Row] {
        try queue.sync {
            let stmt = try prepare(sql, args)
            defer { sqlite3_finalize(stmt) }
            var rows: [Row] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw lastError() }
                var row: Row = [:]
                for i in 0..<sqlite3_column_count(stmt) {
                    let name = String(cString: sqlite3_column_name(stmt, i))
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, i))
                    case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(stmt, i))
                    case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                    case SQLITE_BLOB:
                        let n = Int(sqlite3_column_bytes(stmt, i))
                        if let p = sqlite3_column_blob(stmt, i) {
                            row[name] = .blob(Data(bytes: p, count: n))
                        } else {
                            row[name] = .blob(Data())
                        }
                    default: row[name] = .null
                    }
                }
                rows.append(row)
            }
            return rows
        }
    }

    /// Runs `body` inside a transaction. `body` must use this database's public API.
    public func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Private

    private func prepare(_ sql: String, _ args: [Value?]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg ?? .null {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, Database.transient)
            case .blob(let v):
                _ = v.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, idx, buf.baseAddress, Int32(v.count), Database.transient)
                }
            }
        }
        return stmt
    }

    private func lastError() -> DBError {
        DBError(message: String(cString: sqlite3_errmsg(handle)))
    }
}

// MARK: - Convenience accessors

public extension Database.Value {
    var string: String? { if case .text(let s) = self { return s }; return nil }
    var int: Int? {
        switch self {
        case .int(let v): return Int(v)
        case .double(let v): return Int(v)
        default: return nil
        }
    }
    var double: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }
}

public extension Optional where Wrapped == Database.Value {
    var string: String? { self?.string }
    var int: Int? { self?.int }
    var double: Double? { self?.double }
}

/// Shorthand for building argument lists.
public func v(_ s: String?) -> Database.Value { s.map { .text($0) } ?? .null }
public func v(_ i: Int?) -> Database.Value { i.map { .int(Int64($0)) } ?? .null }
public func v(_ d: Double?) -> Database.Value { d.map { .double($0) } ?? .null }
