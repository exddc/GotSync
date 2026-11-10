import CryptoKit
import Foundation
import SQLite3
import XCTest
@_spi(HostJournalPreview) @testable import GotSync

extension HostJournalStore {
    /// Intake followed by every bounded promotion step, for tests that check
    /// the promoted end state.
    @discardableResult
    func intakeAndPromote(_ arrivals: [HostJournalArrival]) throws -> HostJournalIntake {
        let result = try intake(arrivals)
        while try promote() > 0 {}
        return result
    }
}

enum JournalFixture {
    static let group = Data(repeating: 0x5A, count: 32)
    static let sender = Data(repeating: 0xC0, count: 32)

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func origin(_ byte: UInt8) -> Data { Data(repeating: byte, count: 16) }

    static func mutationID(_ index: Int) -> Data {
        withUnsafeBytes(of: UInt64(index).bigEndian) { Data(repeating: 0x4D, count: 8) + Data($0) }
    }

    /// A contiguous run of records for `origin` starting at `from`.
    static func chain(_ origin: Data, count: Int, from: UInt64 = 1, prior: Data = JournalEnvelope.zeroDigest,
                      payload: (UInt64) -> Data = { Data("r\($0)".utf8) }) throws -> [JournalEnvelope] {
        var result: [JournalEnvelope] = []
        var previous = prior
        for offset in 0..<UInt64(count) {
            let envelope = try JournalEnvelope(origin: origin, sequence: from + offset, prior: previous, payload: payload(from + offset))
            result.append(envelope)
            previous = envelope.digest
        }
        return result
    }

    static func arrival(_ envelopes: [JournalEnvelope], cursor: UInt64, sender: Data = sender) -> HostJournalArrival {
        HostJournalArrival(sender: sender, cursor: cursor, plaintext: Data("message \(cursor)".utf8), envelopes: envelopes.map(\.bytes))
    }

    static func raw(_ bytes: Data, cursor: UInt64, sender: Data = sender) -> HostJournalArrival {
        HostJournalArrival(sender: sender, cursor: cursor, plaintext: bytes, envelopes: nil)
    }

    static func fileHash(_ url: URL) throws -> Data {
        Data(SHA256.hash(data: try Data(contentsOf: url)))
    }

    /// Runs one statement directly against a journal file, as on-disk damage would.
    static func tamper(_ url: URL, _ sql: String, create: Bool = false) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0)
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
            throw JournalStoreError.storeMissing
        }
        defer { sqlite3_close_v2(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw JournalStoreError.storeCorrupt(String(cString: sqlite3_errmsg(database)))
        }
    }

    /// Copies `url` and its rollback journal while a raw transaction with a
    /// one-page cache has spilled pages into the database file, then rolls
    /// that transaction back. The copy is a genuine crash image with a hot
    /// journal; `url` itself ends unchanged.
    static func hotImage(of url: URL, into directory: URL) throws -> URL {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw JournalStoreError.storeMissing
        }
        defer { sqlite3_close_v2(database) }
        let spill = """
            PRAGMA cache_size=1; PRAGMA cache_spill=ON; BEGIN IMMEDIATE;
            UPDATE meta SET value = value + 1000 WHERE key = 'revision';
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 40)
            INSERT INTO heldInbox(sender, cursor, plaintext, digest) SELECT randomblob(32), i, zeroblob(20000), randomblob(32) FROM n;
            """
        guard sqlite3_exec(database, spill, nil, nil, nil) == SQLITE_OK else {
            throw JournalStoreError.storeCorrupt(String(cString: sqlite3_errmsg(database)))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(atPath: url.path, toPath: copy.path)
        try FileManager.default.copyItem(atPath: url.path + "-journal", toPath: copy.path + "-journal")
        sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
        return copy
    }

    /// Bytes of the database and of every sidecar that holds content. The
    /// `-shm` WAL index is SQLite's derived shared memory, which any reader
    /// rewrites, so it is not part of the preserved state.
    static func storedState(_ url: URL) -> [String: Data] {
        var state: [String: Data] = [:]
        for suffix in ["", "-wal", "-journal"] {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: url.path + suffix)) {
                state[suffix] = data
            }
        }
        return state
    }

    @MainActor static func exportAll(_ url: URL, pageSize: Int = 7) throws -> [HostJournalExportItem] {
        var items: [HostJournalExportItem] = []
        var cursor: HostJournalExportCursor?
        repeat {
            let page = try HostJournalFiles.export(url, after: cursor, limit: pageSize)
            items += page.items
            cursor = page.next
        } while cursor != nil
        return items
    }
}

/// A minimal disk-backed host store: outbox, capture counter, applied
/// business records and provenance, saved atomically as one file like the
/// app's single store save.
@MainActor
final class HostStandIn {
    struct State: Codable, Equatable {
        var journalID: Data?
        var enrollmentID: Data?
        var appliedThrough: UInt64 = 0
        var capturedThrough: UInt64 = 0
        var nextMutation = 0
        var outbox: [String: Data] = [:]
        var business: [UInt64: Data] = [:]
    }

    let url: URL
    private(set) var state: State

    init(url: URL) throws {
        self.url = url
        state = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
            : State()
    }

    var provenance: HostJournalProvenance? {
        guard let journalID = state.journalID, let enrollmentID = state.enrollmentID else { return nil }
        return HostJournalProvenance(
            journalID: journalID, enrollmentID: enrollmentID,
            appliedThrough: state.appliedThrough, capturedThrough: state.capturedThrough
        )
    }

    func save(_ provenance: HostJournalProvenance) throws {
        state.journalID = provenance.journalID
        state.enrollmentID = provenance.enrollmentID
        try write()
    }

    /// Saves a new outbox entry together with the incremented capture counter.
    @discardableResult
    func capture(_ payload: Data) throws -> Data {
        state.nextMutation += 1
        let id = JournalFixture.mutationID(state.nextMutation)
        state.outbox[id.base64EncodedString()] = payload
        state.capturedThrough += 1
        try write()
        return id
    }

    func submitOutbox(_ store: HostJournalStore) throws -> [JournalRecordID] {
        let entries = state.outbox.sorted { $0.key < $1.key }
        guard !entries.isEmpty else { return [] }
        let records = try store.submit(
            entries.map { HostJournalMutation(id: Data(base64Encoded: $0.key)!, payload: $0.value) },
            capturedThrough: state.capturedThrough
        )
        state.outbox = [:]
        try write()
        return records
    }

    /// Submits the outbox in capture order, in chunks of at most `maxBytes`
    /// encoded bytes, saving after each accepted chunk; an error leaves the
    /// rest of the outbox for a later retry.
    func submitOutbox(_ store: HostJournalStore, maxBytes: Int) throws -> [JournalRecordID] {
        var records: [JournalRecordID] = []
        var entries = state.outbox.sorted { $0.key < $1.key }
        while !entries.isEmpty {
            var chunk: [(key: String, value: Data)] = []
            var bytes = 0
            for entry in entries {
                let size = JournalEnvelope.headerLength + entry.value.count
                guard chunk.count < 256, bytes + size <= maxBytes else { break }
                chunk.append(entry)
                bytes += size
            }
            records += try store.submit(
                chunk.map { HostJournalMutation(id: Data(base64Encoded: $0.key)!, payload: $0.value) },
                capturedThrough: state.capturedThrough
            )
            for entry in chunk { state.outbox[entry.key] = nil }
            try write()
            entries.removeFirst(chunk.count)
        }
        return records
    }

    func applyAll(_ store: HostJournalStore) throws {
        while true {
            let batch = try store.incoming(after: state.appliedThrough, limit: 64)
            guard let last = batch.last else { return }
            for item in batch { state.business[item.position] = item.payload }
            state.appliedThrough = last.position
            try write()
            try store.markApplied(through: last.position)
        }
    }

    func snapshot() throws -> Data { try Data(contentsOf: url) }

    func restore(_ data: Data) throws {
        try data.write(to: url, options: .atomic)
        state = try JSONDecoder().decode(State.self, from: data)
    }

    private func write() throws {
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }
}

@MainActor
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line, _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("did not throw. \(message)", file: file, line: line)
    } catch {
        handler(error)
    }
}
