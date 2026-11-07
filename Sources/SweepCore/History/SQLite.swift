import Foundation
import SQLite3

public enum SQLValue: Sendable, Hashable {
    case int(Int64), double(Double), text(String), null
    var int: Int64? { if case let .int(v) = self { return v }; if case let .double(d) = self { return Int64(d) }; return nil }
    var double: Double? { if case let .double(v) = self { return v }; if case let .int(i) = self { return Double(i) }; return nil }
    var text: String? { if case let .text(v) = self { return v }; return nil }
}

public struct SQLiteError: Error, CustomStringConvertible { public var description: String }

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal wrapper over the system sqlite3 library. Not thread-safe by itself; callers serialize access.
final class SQLiteDB {
    private var db: OpaquePointer?

    init(path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw SQLiteError(description: "Can't open \(path)")
        }
        sqlite3_busy_timeout(db, 5000)
    }
    deinit { sqlite3_close(db) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"; sqlite3_free(err)
            throw SQLiteError(description: msg)
        }
    }

    @discardableResult
    func query(_ sql: String, _ args: [SQLValue] = []) throws -> [[String: SQLValue]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError(description: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case let .int(v): sqlite3_bind_int64(stmt, idx, v)
            case let .double(v): sqlite3_bind_double(stmt, idx, v)
            case let .text(v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        var rows: [[String: SQLValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError(description: String(cString: sqlite3_errmsg(db))) }
            var row: [String: SQLValue] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(db) }
}
