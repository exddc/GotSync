import CSQLite
import Foundation

final class MLSStore {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL) throws {
        let manager = FileManager.default
        var directoryAttributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        directoryAttributes[.protectionKey] = FileProtectionType.complete
        #endif
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: directoryAttributes)
        try manager.setAttributes(directoryAttributes, ofItemAtPath: directory.path)
        var directoryURL = directory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try directoryURL.setResourceValues(resourceValues)
        let file = directory.appendingPathComponent("mls-v2.sqlite3")
        guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(database)
            database = nil
            throw MLSClientError.storageUnavailable
        }
        do {
            sqlite3_busy_timeout(database, 5000)
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA secure_delete=ON")
            try execute("CREATE TABLE IF NOT EXISTS client (id INTEGER PRIMARY KEY CHECK(id=1), record BLOB NOT NULL)")
            var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
            #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.complete
            #endif
            try manager.setAttributes(attributes, ofItemAtPath: file.path)
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    func read() throws -> ClientRecord {
        guard let record = try optionalRecord() else { throw MLSClientError.invalidState }
        return record
    }

    func update<T>(_ body: (inout ClientRecord?) throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            var record = try optionalRecord()
            let result = try body(&record)
            guard let record else { throw MLSClientError.invalidState }
            let bytes = try JSONEncoder().encode(record)
            guard bytes.count <= 32 * 1024 * 1024 else { throw MLSClientError.capacityReached }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO client VALUES (1, ?)", -1, &statement, nil) == SQLITE_OK else { throw MLSClientError.storageUnavailable }
            defer { sqlite3_finalize(statement) }
            let bound = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), transient) }
            guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw MLSClientError.storageUnavailable }
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func optionalRecord() throws -> ClientRecord? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT record FROM client WHERE id=1", -1, &statement, nil) == SQLITE_OK else { throw MLSClientError.storageUnavailable }
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            let count = sqlite3_column_bytes(statement, 0)
            guard count > 0, count <= 32 * 1024 * 1024,
                  let bytes = sqlite3_column_blob(statement, 0) else { throw MLSClientError.storageUnavailable }
            return try JSONDecoder().decode(ClientRecord.self, from: Data(bytes: bytes, count: Int(count)))
        case SQLITE_DONE: return nil
        default: throw MLSClientError.storageUnavailable
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw MLSClientError.storageUnavailable }
    }
}
