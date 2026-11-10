import Foundation
import SQLite3

enum JournalValue: Hashable, Codable, Sendable {
    case integer(Int64)
    case blob(Data)
    case text(String)
    case null
}

/// A checked SQLite connection. Every unsigned value crosses into SQLite
/// through `integer(_:)`, which refuses values above `Int64.max` instead of
/// wrapping them.
final class JournalDatabase {
    /// `SQLITE_READONLY_ROLLBACK`: a read-only connection found a hot
    /// rollback journal that only a read-write connection may roll back.
    static let hotJournalCode = SQLITE_READONLY | (3 << 8)
    static let defaultBusyTimeoutMilliseconds: Int32 = 5_000
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL, readOnly: Bool, create: Bool = false, busyTimeoutMilliseconds: Int32 = defaultBusyTimeoutMilliseconds) throws {
        var flags = SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_FULLMUTEX
        flags |= readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        if create {
            flags |= SQLITE_OPEN_CREATE
        }
        guard let parent = realpath(url.deletingLastPathComponent().path, nil) else {
            throw JournalStoreError.storeMissing
        }
        defer { free(parent) }
        let path = URL(fileURLWithPath: String(cString: parent)).appendingPathComponent(url.lastPathComponent).path
        var database: OpaquePointer?
        let code = sqlite3_open_v2(path, &database, flags, nil)
        guard code == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close_v2(database)
            throw JournalStoreError.storage(code: code, message: message)
        }
        handle = database
        sqlite3_extended_result_codes(database, 1)
        sqlite3_busy_timeout(database, busyTimeoutMilliseconds)
    }

    /// Replaces any busy handler with a plain timeout.
    func setBusyTimeout(_ milliseconds: Int32) {
        sqlite3_busy_timeout(handle, milliseconds)
    }

    /// Whether the file this connection opened is no longer at its path.
    func hasMoved() throws -> Bool {
        var moved: Int32 = 0
        let code = sqlite3_file_control(handle, "main", SQLITE_FCNTL_HAS_MOVED, &moved)
        guard code == SQLITE_OK else { throw error(code) }
        return moved != 0
    }

    /// Makes long statements and lock waits give up once `cancellation` is
    /// set. It must outlive this connection.
    func observe(_ cancellation: HostJournalCancellation) {
        let context = Unmanaged.passUnretained(cancellation).toOpaque()
        sqlite3_progress_handler(handle, 1_000, { context in
            Unmanaged<HostJournalCancellation>.fromOpaque(context!).takeUnretainedValue().isCancelled ? 1 : 0
        }, context)
        sqlite3_busy_handler(handle, { context, attempts in
            let cancellation = Unmanaged<HostJournalCancellation>.fromOpaque(context!).takeUnretainedValue()
            guard !cancellation.isCancelled, attempts < 500 else { return 0 }
            usleep(10_000)
            return 1
        }, context)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// Whether a transaction is open on this connection.
    var isInTransaction: Bool { sqlite3_get_autocommit(handle) == 0 }

    static func integer(_ value: UInt64) throws -> JournalValue {
        guard value <= UInt64(Int64.max) else {
            throw JournalStoreError.valueOutOfRange
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

    private func error(_ code: Int32) -> JournalStoreError {
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
            throw JournalStoreError.storeCorrupt("column \(column) is not an integer")
        }
        return sqlite3_column_int64(statement, column)
    }

    func unsigned(_ column: Int32) throws -> UInt64 {
        let value = try int64(column)
        guard value >= 0 else {
            throw JournalStoreError.storeCorrupt("column \(column) is negative")
        }
        return UInt64(value)
    }

    func blob(_ column: Int32) throws -> Data {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB else {
            throw JournalStoreError.storeCorrupt("column \(column) is not a blob")
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let pointer = sqlite3_column_blob(statement, column) else {
            return Data()
        }
        return Data(bytes: pointer, count: count)
    }

    func text(_ column: Int32) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT, let pointer = sqlite3_column_text(statement, column) else {
            throw JournalStoreError.storeCorrupt("column \(column) is not text")
        }
        return String(cString: pointer)
    }
}
