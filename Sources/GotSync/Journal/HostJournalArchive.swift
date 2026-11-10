import Foundation

enum HostJournalListing: Equatable, Sendable {
    case journal(url: URL, view: HostJournalCoreView)
    /// Present but not readable as a journal. It is kept and counts against
    /// link admission.
    case unreadable(url: URL, reason: String)
    /// A creation that never reached its final name; it owns no records.
    case incomplete(url: URL)
}

enum HostJournalExportItem: Equatable, Sendable {
    case own(sequence: UInt64, mutationID: Data?, envelope: Data)
    case remote(position: UInt64, origin: Data, sequence: UInt64, applied: Bool, envelope: Data)
    case pending(origin: Data, sequence: UInt64, envelope: Data)
    case quarantined(sender: Data, cursor: UInt64, reason: String, bytes: Data)
    case held(sender: Data, cursor: UInt64, plaintext: Data)
}

/// Where the next export page starts. A cursor belongs to one journal and
/// one committed revision; a continuation after any commit is refused.
struct HostJournalExportCursor: Hashable, Codable, Sendable {
    let journalID: Data
    let revision: UInt64
    let section: Int
    let key: [JournalValue]
}

struct HostJournalExportPage: Equatable, Sendable {
    let items: [HostJournalExportItem]
    let next: HostJournalExportCursor?
}

struct HostJournalAccounting: Equatable, Sendable {
    struct Category: Equatable, Sendable {
        let rows: UInt64
        let bytes: UInt64
    }

    /// Logical content by table column.
    let categories: [String: Category]
    let databaseBytes: UInt64
    let sidecarBytes: UInt64
    let allocatedBytes: UInt64
    let freeBytes: UInt64
}

/// Read-only access to journal files, whether or not a journal is active or
/// enrolled, plus the one explicit destructive operation on a retired file.
@MainActor
enum HostJournalFiles {
    /// New links are refused while this many retired or unreadable journals exist.
    static let linkAdmissionLimit = 4

    nonisolated static func discover(in directory: URL) throws -> [HostJournalListing] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        var listings: [HostJournalListing] = []
        for name in names where name.hasPrefix(HostJournalStore.filePrefix) {
            let url = directory.appendingPathComponent(name)
            if name.hasSuffix(HostJournalStore.fileSuffix + HostJournalStore.creatingSuffix) {
                listings.append(.incomplete(url: url))
            } else if name.hasSuffix(HostJournalStore.fileSuffix) {
                do {
                    listings.append(.journal(url: url, view: try read(url) { try HostJournalStore.readMeta($0).view }))
                } catch {
                    listings.append(.unreadable(url: url, reason: "\(error)"))
                }
            }
        }
        return listings
    }

    static func admitsNewLink(_ listings: [HostJournalListing]) -> Bool {
        let held = listings.filter {
            switch $0 {
            case .journal(_, let view): view.isRetired
            case .unreadable: true
            case .incomplete: false
            }
        }
        return held.count < linkAdmissionLimit
    }

    /// One page of every owned class, in a fixed order: own records, remote
    /// records, pending records, quarantined messages, held inbox messages.
    static func export(_ url: URL, after cursor: HostJournalExportCursor?, limit: Int) throws -> HostJournalExportPage {
        guard limit > 0, limit <= 1_024 else { throw JournalStoreError.invalidArgument("limit") }
        return try read(url) { database in
            let meta = try HostJournalStore.readMeta(database)
            if let cursor {
                guard cursor.journalID == meta.journalID else { throw JournalStoreError.exportCursorMismatch }
                guard cursor.revision == meta.revision else { throw JournalStoreError.exportRevisionChanged }
            }
            var items: [(Int, [JournalValue], HostJournalExportItem)] = []
            var section = cursor?.section ?? 0
            var key = cursor?.key
            while section < sections.count, items.count < limit {
                let query = sections[section]
                var sql = query.select
                var values: [JournalValue] = query.base(meta)
                if let key {
                    sql += (query.select.contains(" WHERE ") ? " AND " : " WHERE ") + query.after
                    values += key
                }
                sql += " ORDER BY \(query.order) LIMIT ?"
                values.append(.integer(Int64(limit - items.count)))
                try database.rows(sql, values) { row in
                    let item = try query.item(row, meta)
                    items.append((section, try query.key(row), item))
                }
                if items.count < limit {
                    section += 1
                    key = nil
                }
            }
            let next = items.count == limit ? items.last.map {
                HostJournalExportCursor(journalID: meta.journalID, revision: meta.revision, section: $0.0, key: $0.1)
            } : nil
            return HostJournalExportPage(items: items.map(\.2), next: next)
        }
    }

    /// Deletes one retired journal file. `confirming` must repeat its ID.
    static func discard(in directory: URL, journalID: Data, confirming: Data) throws {
        guard confirming == journalID else { throw JournalStoreError.confirmationMismatch }
        let url = HostJournalStore.fileURL(in: directory, journalID: journalID)
        let view = try read(url) { try HostJournalStore.readMeta($0).view }
        guard view.journalID == journalID, view.isRetired else { throw JournalStoreError.notArchived }
        let sidecar = URL(fileURLWithPath: url.path + "-journal")
        if FileManager.default.fileExists(atPath: sidecar.path) {
            throw JournalStoreError.storeUnreadable("unrecovered transaction")
        }
        try FileManager.default.removeItem(at: url)
    }

    static func accounting(_ url: URL) throws -> HostJournalAccounting {
        var categories: [String: HostJournalAccounting.Category] = [:]
        let (pages, pageSize, free) = try read(url) { database -> (UInt64, UInt64, UInt64) in
            let meta = try HostJournalStore.readMeta(database)
            let queries: [(String, String, [JournalValue])] = [
                ("records.own.envelope", "SELECT COUNT(*), COALESCE(SUM(length(envelope)), 0) FROM records WHERE origin = ?", [.blob(meta.origin)]),
                ("records.remote.envelope", "SELECT COUNT(*), COALESCE(SUM(length(envelope)), 0) FROM records WHERE origin <> ?", [.blob(meta.origin)]),
                ("records.identity", "SELECT COUNT(*), COALESCE(SUM(length(origin) + length(digest) + 16), 0) FROM records", []),
                ("submissions", "SELECT COUNT(*), COALESCE(SUM(length(id) + length(payloadDigest) + 8), 0) FROM submissions", []),
                ("pending.envelope", "SELECT COUNT(*), COALESCE(SUM(length(envelope)), 0) FROM pending", []),
                ("pending.identity", "SELECT COUNT(*), COALESCE(SUM(length(origin) + length(digest) + 8), 0) FROM pending", []),
                ("quarantine.bytes", "SELECT COUNT(*), COALESCE(SUM(length(bytes)), 0) FROM quarantine", []),
                ("quarantine.identity", "SELECT COUNT(*), COALESCE(SUM(length(sender) + length(digest) + length(reason) + 8), 0) FROM quarantine", []),
                ("held.plaintext", "SELECT COUNT(*), COALESCE(SUM(length(plaintext)), 0) FROM heldInbox", []),
                ("held.identity", "SELECT COUNT(*), COALESCE(SUM(length(sender) + length(digest) + 8), 0) FROM heldInbox", []),
                ("origins", "SELECT COUNT(*), COALESCE(SUM(length(origin) + length(head) + 16), 0) FROM origins", []),
            ]
            for (name, sql, values) in queries {
                categories[name] = try database.first(sql, values) {
                    HostJournalAccounting.Category(rows: try $0.unsigned(0), bytes: try $0.unsigned(1))
                }
            }
            func pragma(_ name: String) throws -> UInt64 {
                try database.first("PRAGMA \(name)", [], { try $0.unsigned(0) }) ?? 0
            }
            return (try pragma("page_count"), try pragma("page_size"), try pragma("freelist_count"))
        }
        func size(_ path: String) -> UInt64 {
            ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.uint64Value ?? 0
        }
        return HostJournalAccounting(
            categories: categories,
            databaseBytes: size(url.path),
            sidecarBytes: ["-journal", "-wal", "-shm"].reduce(0) { $0 + size(url.path + $1) },
            allocatedBytes: pages * pageSize,
            freeBytes: free * pageSize
        )
    }

    nonisolated private static func read<T>(_ url: URL, _ body: (JournalDatabase) throws -> T) throws -> T {
        try HostJournalStore.requireRegularFile(url)
        let database = try JournalDatabase(url: url, readOnly: true)
        try database.execute("PRAGMA query_only=1")
        try database.execute("BEGIN")
        defer { try? database.execute("COMMIT") }
        try HostJournalStore.checkFormat(database)
        return try body(database)
    }

    private struct Section {
        let select: String
        let base: (HostJournalStore.Meta) -> [JournalValue]
        let after: String
        let order: String
        let key: (JournalRow) throws -> [JournalValue]
        let item: (JournalRow, HostJournalStore.Meta) throws -> HostJournalExportItem
    }

    private static let sections: [Section] = [
        Section(
            select: "SELECT r.sequence, s.id, r.envelope FROM records r LEFT JOIN submissions s ON s.sequence = r.sequence WHERE r.origin = ?",
            base: { [.blob($0.origin)] },
            after: "r.sequence > ?",
            order: "r.sequence",
            key: { [.integer(try $0.int64(0))] },
            item: { row, _ in
                .own(sequence: try row.unsigned(0), mutationID: row.isNull(1) ? nil : try row.blob(1), envelope: try row.blob(2))
            }
        ),
        Section(
            select: "SELECT position, origin, sequence, envelope FROM records WHERE position IS NOT NULL",
            base: { _ in [] },
            after: "position > ?",
            order: "position",
            key: { [.integer(try $0.int64(0))] },
            item: { row, meta in
                let position = try row.unsigned(0)
                return .remote(
                    position: position, origin: try row.blob(1), sequence: try row.unsigned(2),
                    applied: position <= meta.appliedThrough, envelope: try row.blob(3)
                )
            }
        ),
        Section(
            select: "SELECT origin, sequence, envelope FROM pending",
            base: { _ in [] },
            after: "(origin, sequence) > (?, ?)",
            order: "origin, sequence",
            key: { [.blob(try $0.blob(0)), .integer(try $0.int64(1))] },
            item: { row, _ in .pending(origin: try row.blob(0), sequence: try row.unsigned(1), envelope: try row.blob(2)) }
        ),
        Section(
            select: "SELECT sender, cursor, reason, bytes FROM quarantine",
            base: { _ in [] },
            after: "(sender, cursor) > (?, ?)",
            order: "sender, cursor",
            key: { [.blob(try $0.blob(0)), .integer(try $0.int64(1))] },
            item: { row, _ in
                .quarantined(sender: try row.blob(0), cursor: try row.unsigned(1), reason: try row.text(2), bytes: try row.blob(3))
            }
        ),
        Section(
            select: "SELECT sender, cursor, plaintext FROM heldInbox",
            base: { _ in [] },
            after: "(sender, cursor) > (?, ?)",
            order: "sender, cursor",
            key: { [.blob(try $0.blob(0)), .integer(try $0.int64(1))] },
            item: { row, _ in .held(sender: try row.blob(0), cursor: try row.unsigned(1), plaintext: try row.blob(2)) }
        ),
    ]
}
