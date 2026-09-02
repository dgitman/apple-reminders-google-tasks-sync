import Foundation
import SQLite3

/// Minimal SQLite wrapper — enough for the state store and the read-only Reminders database.
public final class SQLiteDB {
    private var db: OpaquePointer?
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String, readOnly: Bool = false) throws {
        var handle: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            if let handle { sqlite3_close(handle) }
            throw RemTasksError("Cannot open SQLite database at \(path): \(msg)")
        }
        db = handle
        sqlite3_busy_timeout(db, 5000)
    }

    deinit { if let db { sqlite3_close(db) } }

    public enum Value {
        case null, int(Int64), real(Double), text(String)
        public var string: String? { if case .text(let s) = self { return s }; if case .int(let i) = self { return String(i) }; return nil }
        public var int: Int64? { if case .int(let i) = self { return i }; if case .real(let d) = self { return Int64(d) }; return nil }
        public var double: Double? { if case .real(let d) = self { return d }; if case .int(let i) = self { return Double(i) }; return nil }
    }

    public struct Row {
        public let columns: [String: Value]
        public subscript(_ name: String) -> Value { columns[name] ?? .null }
    }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw RemTasksError("SQLite error: \(msg) in: \(sql)")
        }
    }

    @discardableResult
    public func run(_ sql: String, _ params: [Any?] = []) throws -> [Row] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw RemTasksError("SQLite prepare failed: \(String(cString: sqlite3_errmsg(db))) in: \(sql)")
        }
        defer { sqlite3_finalize(stmt) }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as Bool: sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as Date: sqlite3_bind_double(stmt, idx, v.timeIntervalSince1970)
            default: throw RemTasksError("Unsupported SQLite parameter type: \(type(of: p!))")
            }
        }
        var rows: [Row] = []
        let colCount = Int(sqlite3_column_count(stmt))
        let names = (0..<colCount).map { String(cString: sqlite3_column_name(stmt, Int32($0))) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw RemTasksError("SQLite step failed: \(String(cString: sqlite3_errmsg(db))) in: \(sql)")
            }
            var cols: [String: Value] = [:]
            for c in 0..<colCount {
                let i = Int32(c)
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: cols[names[c]] = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: cols[names[c]] = .real(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: cols[names[c]] = .text(String(cString: sqlite3_column_text(stmt, i)))
                default: cols[names[c]] = .null
                }
            }
            rows.append(Row(columns: cols))
        }
        return rows
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(db) }
    public var changes: Int { Int(sqlite3_changes(db)) }
}
