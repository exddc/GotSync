import Foundation
import SQLite3

enum JournalValue: Hashable, Sendable {
    case integer(Int64)
    case blob(Data)
    case text(String)
    case null
}

/// A checked SQLite connection. Every unsigned value crosses into SQLite
/// through `integer(_:)`, which refuses values above `Int64.max` instead of
/// wrapping them.
final class JournalDatabase {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL, readOnly: Bool, create: Bool = false) throws {
        var flags = SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_FULLMUTEX
        flags |= readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        if create {
            flags |= SQLITE_OPEN_CREATE
        }
        guard let parent = realpath(url.deletingLastPathComponent().path, nil) else {
            throw HostJournalError.storeMissing
        }
        defer { free(parent) }
        let path = URL(fileURLWithPath: String(cString: parent)).appendingPathComponent(url.lastPathComponent).path
        var database: OpaquePointer?
        let code = sqlite3_open_v2(path, &database, flags, nil)
        guard code == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close_v2(database)
            throw HostJournalError.storage(code: code, message: message)
        }
        handle = database
        sqlite3_extended_result_codes(database, 1)
        sqlite3_busy_timeout(database, 5_000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    static func integer(_ value: UInt64) throws -> JournalValue {
        guard value <= UInt64(Int64.max) else {
            throw HostJournalError.valueOutOfRange
        }
        return .integer(Int64(value))
    }

    func execute(_ sql: String) throws {
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        guard code == SQLITE_OK else {
            throw error(code)
        }
    }

    @discardableResult
    func run(_ sql: String, _ values: [JournalValue] = []) throws -> Int {
        try withStatement(sql, values) { statement in
            let code = sqlite3_step(statement)
            guard code == SQLITE_DONE else {
                throw error(code)
            }
        }
        return Int(sqlite3_changes(handle))
    }

    func rows(_ sql: String, _ values: [JournalValue] = [], _ body: (JournalRow) throws -> Void) throws {
        try withStatement(sql, values) { statement in
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE {
                    return
                }
                guard code == SQLITE_ROW else {
                    throw error(code)
                }
                try body(JournalRow(statement: statement))
            }
        }
    }

    func first<T>(_ sql: String, _ values: [JournalValue] = [], _ body: (JournalRow) throws -> T) throws -> T? {
        var result: T?
        try rows(sql, values) { row in
            if result == nil {
                result = try body(row)
            }
        }
        return result
    }

    private func withStatement(_ sql: String, _ values: [JournalValue], _ body: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            throw error(prepared)
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .integer(let integer):
                code = sqlite3_bind_int64(statement, index, integer)
            case .blob(let data) where data.isEmpty:
                code = sqlite3_bind_zeroblob(statement, index, 0)
            case .blob(let data):
                code = data.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient)
                }
            case .text(let text):
                code = sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .null:
                code = sqlite3_bind_null(statement, index)
            }
            guard code == SQLITE_OK else {
                throw error(code)
            }
        }
        try body(statement)
    }

    private func error(_ code: Int32) -> HostJournalError {
        .storage(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }
}

struct JournalRow {
    fileprivate let statement: OpaquePointer

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    func int64(_ column: Int32) throws -> Int64 {
        guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else {
            throw HostJournalError.storeCorrupt("column \(column) is not an integer")
        }
        return sqlite3_column_int64(statement, column)
    }

    func unsigned(_ column: Int32) throws -> UInt64 {
        let value = try int64(column)
        guard value >= 0 else {
            throw HostJournalError.storeCorrupt("column \(column) is negative")
        }
        return UInt64(value)
    }

    func blob(_ column: Int32) throws -> Data {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB else {
            throw HostJournalError.storeCorrupt("column \(column) is not a blob")
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let pointer = sqlite3_column_blob(statement, column) else {
            return Data()
        }
        return Data(bytes: pointer, count: count)
    }

    func text(_ column: Int32) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT, let pointer = sqlite3_column_text(statement, column) else {
            throw HostJournalError.storeCorrupt("column \(column) is not text")
        }
        return String(cString: pointer)
    }
}
