import Foundation
import os
import SQLite3

/// A cancellation flag that SQLite handlers and Swift loops both poll.
final class HostJournalCancellation: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    var isCancelled: Bool { state.withLock { $0 } }

    func cancel() {
        state.withLock { $0 = true }
    }
}

/// What identifies the prepared file and its committed state: the inode the
/// path named while SQLite held its shared lock, and the SQLite header's
/// change counter, page count and schema cookie.
struct HostJournalFileToken: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let header: Data
}

/// A journal validated away from the main actor. Holds values only, never a
/// connection.
struct PreparedHostJournal: Sendable {
    let url: URL
    let token: HostJournalFileToken
    let view: HostJournalCoreView
}

/// Validates a journal on a connection owned by this call alone. The engine
/// is the only cooperating writer of journal files and serializes its own
/// changes to them with opening; the token detects ordinary change, not a
/// hostile process that restores file metadata.
enum HostJournalPreparation {
    static func prepare(_ url: URL, cancellation: HostJournalCancellation) throws -> PreparedHostJournal {
        try HostJournalStore.requireRegularFile(url)
        do {
            do {
                return try snapshot(url, cancellation)
            } catch HostJournalError.storage(let code, _) where code == JournalDatabase.hotJournalCode {
                try recover(url, cancellation)
                return try snapshot(url, cancellation)
            }
        } catch HostJournalError.storage(let code, let message) {
            if cancellation.isCancelled { throw CancellationError() }
            throw HostJournalError.storeUnreadable("\(code): \(message)")
        }
    }

    /// Lets SQLite roll back a hot journal, which only a read-write
    /// connection may do.
    private static func recover(_ url: URL, _ cancellation: HostJournalCancellation) throws {
        let database = try JournalDatabase(url: url, readOnly: false)
        database.observe(cancellation)
        try database.execute("BEGIN")
        defer { try? database.execute("COMMIT") }
        _ = try database.first("SELECT COUNT(*) FROM meta", [], { try $0.int64(0) })
    }

    private static func snapshot(_ url: URL, _ cancellation: HostJournalCancellation) throws -> PreparedHostJournal {
        let database = try JournalDatabase(url: url, readOnly: true)
        database.observe(cancellation)
        try database.execute("BEGIN")
        defer { try? database.execute("COMMIT") }
        try HostJournalStore.checkFormat(database)
        let mode = try database.first("PRAGMA journal_mode", [], { try $0.text(0) }) ?? ""
        guard mode == "delete" else {
            throw HostJournalError.storeCorrupt("journal mode \(mode)")
        }
        let token = try fileToken(url, database)
        let view = try HostJournalStore.validate(database, cancellation: cancellation)
        return PreparedHostJournal(url: url, token: token, view: view)
    }

    /// Reads the token while `database` holds a lock: the path must still
    /// name the inode SQLite opened, before and after reading the header.
    static func fileToken(_ url: URL, _ database: JournalDatabase) throws -> HostJournalFileToken {
        guard try !database.hasMoved() else { throw HostJournalError.storeUnreadable("moved while opening") }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw HostJournalError.storeMissing }
        defer { close(descriptor) }
        var opened = stat()
        var named = stat()
        guard fstat(descriptor, &opened) == 0, stat(url.path, &named) == 0,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino
        else {
            throw HostJournalError.storeUnreadable("replaced while opening")
        }
        var header = [UInt8](repeating: 0, count: 100)
        guard pread(descriptor, &header, 100, 0) == 100 else { throw HostJournalError.storeCorrupt("header") }
        guard try !database.hasMoved() else { throw HostJournalError.storeUnreadable("moved while opening") }
        return HostJournalFileToken(
            device: UInt64(opened.st_dev), inode: UInt64(opened.st_ino), header: Data(header[24..<32] + header[40..<44])
        )
    }
}
