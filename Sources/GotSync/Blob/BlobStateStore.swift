import Darwin
import Foundation

/// The library's blob storage under one directory:
///
/// - `state.sqlite3`: binding, outgoing and incoming rows, available registry
/// - `staging/<id>.clone`: the private clone a seal reads
/// - `sealed/<id>.<generation>`: sealed ciphertext until the relay holds it
/// - `incoming/<id>.ct`: received parts at their ciphertext offsets
/// - `incoming/<id>.open`: opened plaintext before it is verified
/// - `verified/<id>`: verified content awaiting host publication
/// - `reupload/<object>.ct`: ciphertext re-derived for a re-upload
///
/// `<id>` is the lowercase hex transfer ID. Files outside a committed row are
/// leftovers of interrupted work and are deleted when the store opens.
struct BlobFiles: Sendable {
    let root: URL

    var database: URL { root.appendingPathComponent("state.sqlite3") }
    var staging: URL { root.appendingPathComponent("staging", isDirectory: true) }
    var sealed: URL { root.appendingPathComponent("sealed", isDirectory: true) }
    var incoming: URL { root.appendingPathComponent("incoming", isDirectory: true) }
    var verified: URL { root.appendingPathComponent("verified", isDirectory: true) }
    var reupload: URL { root.appendingPathComponent("reupload", isDirectory: true) }

    func clone(_ id: Data) -> URL { staging.appendingPathComponent("\(id.hexString).clone") }
    func sealedFile(_ id: Data, generation: Int) -> URL { sealed.appendingPathComponent("\(id.hexString).\(generation)") }
    func ciphertext(_ id: Data) -> URL { incoming.appendingPathComponent("\(id.hexString).ct") }
    func opened(_ id: Data) -> URL { incoming.appendingPathComponent("\(id.hexString).open") }
    func verifiedFile(_ id: Data) -> URL { verified.appendingPathComponent(id.hexString) }
    func reuploadFile(_ objectID: Data) -> URL { reupload.appendingPathComponent("\(objectID.hexString).ct") }

    func prepareDirectories() throws {
        let manager = FileManager.default
        for directory in [root, staging, sealed, incoming, verified, reupload] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: ProtectedStorage.directoryAttributes)
        }
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var target = root
        try target.setResourceValues(excluded)
    }

    /// Creates an empty, protected file for exclusive writing.
    static func create(_ url: URL) throws -> FileHandle {
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: ProtectedStorage.fileAttributes) else {
            throw BlobError.storageUnavailable
        }
        return try FileHandle(forUpdating: url)
    }

    static func size(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return size.int64Value
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Makes a rename or a new file in `directory` durable.
    static func synchronize(directory: URL) {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        fsync(descriptor)
        close(descriptor)
    }

    /// Bytes free to this process on the volume holding `url`.
    static func freeBytes(at url: URL) -> Int64? {
        var stats = statvfs()
        guard statvfs(url.path, &stats) == 0 else { return nil }
        return Int64(stats.f_bavail) * Int64(stats.f_frsize)
    }
}

struct BlobBindingRecord: Equatable {
    var route: Data
    /// The member fingerprint whose session this is.
    var member: Data
    var session: Data
    var retired: Bool
    var generation: UInt64
}

enum BlobOutgoingPhase: Int64 {
    case sealed = 0, uploaded = 1, offered = 2, repairRequired = 3, failed = 4
}

struct BlobOutgoingRow {
    var id: Data
    var kind: BlobContentKind
    var route: Data
    var session: Data
    var expected: Data
    var source: String
    var phase: BlobOutgoingPhase
    var sealGeneration: Int
    var key: Data
    var objectID: Data
    var plaintextLength: UInt64
    var partHashes: [Data]
    var mediaType: String
    var pixelWidth: UInt32
    var pixelHeight: UInt32
    var descriptor: Data?
    var digest: Data?
    var failure: String?
    var attempts: Int
    var retryAt: Double

    var layout: BlobPartLayout {
        get throws { try BlobPartLayout(plaintextLength: plaintextLength) }
    }

    func manifest() throws -> BlobManifest {
        try BlobManifest(route: BlobRoute(route), ciphertextLength: layout.ciphertextLength, partHashes: partHashes)
    }

    func frozenDescriptor() throws -> BlobDescriptor {
        if kind == .applicationData {
            return try BlobDescriptor(dataObjectID: objectID, key: key, plaintextLength: plaintextLength, contentHash: expected)
        }
        return try BlobDescriptor(
            objectID: objectID, key: key, plaintextLength: plaintextLength, contentHash: expected,
            pixelWidth: pixelWidth, pixelHeight: pixelHeight, mediaType: mediaType
        )
    }
}

enum BlobIncomingPhase: Int64 {
    case queued = 0, fetching = 1, unavailable = 2, rejected = 3, verified = 4, retired = 5

    /// Rows in these phases hold or reserve library bytes.
    var holdsBytes: Bool { self == .fetching || self == .verified }
}

struct BlobIncomingRow {
    var id: Data
    var route: Data
    var session: Data
    var descriptor: Data
    var digest: Data
    var objectID: Data
    var phase: BlobIncomingPhase
    /// Bit `i` set: part `i` is stored and fsynced in the ciphertext file.
    var present: UInt32
    var attempts: Int
    var rejection: String?
    var retryAt: Double

    /// The kind its descriptor declares; checked when the row was queued.
    var kind: BlobContentKind {
        descriptor.count > 4 && descriptor[descriptor.startIndex + 4] == BlobDescriptor.dataVersion ? .applicationData : .image
    }
}

/// The service actor's SQLite store. Every method is synchronous and runs
/// inside one actor segment.
final class BlobStateStore {
    private let database: JournalDatabase

    init(files: BlobFiles) throws {
        try files.prepareDirectories()
        let existed = FileManager.default.fileExists(atPath: files.database.path)
        database = try JournalDatabase(url: files.database, readOnly: false, create: true)
        try database.execute("PRAGMA journal_mode=DELETE")
        try database.execute("PRAGMA synchronous=FULL")
        try database.execute("""
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS outgoing (
                id BLOB PRIMARY KEY, route BLOB NOT NULL, session BLOB NOT NULL, expected BLOB NOT NULL,
                source TEXT NOT NULL, phase INTEGER NOT NULL, seal_generation INTEGER NOT NULL,
                key BLOB NOT NULL, object BLOB NOT NULL, length INTEGER NOT NULL, hashes BLOB NOT NULL,
                media TEXT NOT NULL, width INTEGER NOT NULL, height INTEGER NOT NULL,
                descriptor BLOB, digest BLOB, failure TEXT, attempts INTEGER NOT NULL, retry_at INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS incoming (
                id BLOB PRIMARY KEY, route BLOB NOT NULL, session BLOB NOT NULL, descriptor BLOB NOT NULL,
                digest BLOB NOT NULL, object BLOB NOT NULL, phase INTEGER NOT NULL, present INTEGER NOT NULL,
                attempts INTEGER NOT NULL, rejection TEXT, retry_at INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS available (
                route BLOB NOT NULL, object BLOB NOT NULL, descriptor BLOB NOT NULL, PRIMARY KEY (route, object));
            """)
        var columns: Set<String> = []
        try database.rows("PRAGMA table_info(outgoing)") { columns.insert(try $0.text(1)) }
        if !columns.contains("kind") {
            try database.execute("ALTER TABLE outgoing ADD COLUMN kind INTEGER NOT NULL DEFAULT 0")
        }
        if !existed {
            try FileManager.default.setAttributes(ProtectedStorage.fileAttributes, ofItemAtPath: files.database.path)
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try database.execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try database.execute("COMMIT")
            return result
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    // MARK: Binding

    func binding() throws -> BlobBindingRecord? {
        var values: [String: Data] = [:]
        try database.rows("SELECT key, value FROM meta") { values[try $0.text(0)] = try $0.blob(1) }
        guard let route = values["route"], let member = values["member"], let session = values["session"],
              let retired = values["retired"], let generation = values["generation"], generation.count == 8
        else {
            return nil
        }
        return BlobBindingRecord(
            route: route, member: member, session: session, retired: retired == Data([1]),
            generation: generation.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
        )
    }

    func save(_ binding: BlobBindingRecord) throws {
        var generation = Data()
        generation.appendBigEndian(binding.generation)
        try transaction {
            for (key, value) in [
                ("route", binding.route), ("member", binding.member), ("session", binding.session),
                ("retired", Data([binding.retired ? 1 : 0])), ("generation", generation),
            ] {
                try database.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [.text(key), .blob(value)])
            }
        }
    }

    // MARK: Outgoing

    private static let outgoingColumns = """
        id, route, session, expected, source, phase, seal_generation, key, object, length, hashes, media,
        width, height, descriptor, digest, failure, attempts, retry_at, kind
        """

    func outgoing(_ id: Data) throws -> BlobOutgoingRow? {
        try database.first("SELECT \(Self.outgoingColumns) FROM outgoing WHERE id = ?", [.blob(id)], Self.outgoingRow)
    }

    func allOutgoing() throws -> [BlobOutgoingRow] {
        var rows: [BlobOutgoingRow] = []
        try database.rows("SELECT \(Self.outgoingColumns) FROM outgoing ORDER BY id") { rows.append(try Self.outgoingRow($0)) }
        return rows
    }

    func outgoingCount() throws -> Int {
        try database.first("SELECT COUNT(*) FROM outgoing", []) { Int(try $0.int64(0)) } ?? 0
    }

    func put(_ row: BlobOutgoingRow) throws {
        try database.run(
            "INSERT OR REPLACE INTO outgoing (\(Self.outgoingColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                .blob(row.id), .blob(row.route), .blob(row.session), .blob(row.expected), .text(row.source),
                .integer(row.phase.rawValue), .integer(Int64(row.sealGeneration)), .blob(row.key), .blob(row.objectID),
                try JournalDatabase.integer(row.plaintextLength), .blob(row.partHashes.reduce(Data(), +)), .text(row.mediaType),
                .integer(Int64(row.pixelWidth)), .integer(Int64(row.pixelHeight)),
                row.descriptor.map { .blob($0) } ?? .null, row.digest.map { .blob($0) } ?? .null,
                row.failure.map { .text($0) } ?? .null, .integer(Int64(row.attempts)), .integer(Int64(row.retryAt * 1_000)),
                .integer(row.kind == .image ? 0 : 1),
            ]
        )
    }

    func deleteOutgoing(_ id: Data) throws {
        try database.run("DELETE FROM outgoing WHERE id = ?", [.blob(id)])
    }

    private static func outgoingRow(_ row: JournalRow) throws -> BlobOutgoingRow {
        let hashes = try row.blob(10)
        let kind = try row.int64(19)
        guard hashes.count % BlobFormat.hashLength == 0,
              let phase = BlobOutgoingPhase(rawValue: try row.int64(5)),
              kind == 0 || kind == 1
        else {
            throw BlobError.storageUnavailable
        }
        return BlobOutgoingRow(
            id: try row.blob(0), kind: kind == 0 ? .image : .applicationData, route: try row.blob(1), session: try row.blob(2), expected: try row.blob(3),
            source: try row.text(4), phase: phase, sealGeneration: Int(try row.int64(6)), key: try row.blob(7),
            objectID: try row.blob(8), plaintextLength: try row.unsigned(9),
            partHashes: stride(from: 0, to: hashes.count, by: BlobFormat.hashLength).map {
                Data(hashes[hashes.startIndex + $0 ..< hashes.startIndex + $0 + BlobFormat.hashLength])
            },
            mediaType: try row.text(11), pixelWidth: UInt32(try row.unsigned(12)), pixelHeight: UInt32(try row.unsigned(13)),
            descriptor: row.isNull(14) ? nil : try row.blob(14), digest: row.isNull(15) ? nil : try row.blob(15),
            failure: row.isNull(16) ? nil : try row.text(16), attempts: Int(try row.int64(17)),
            retryAt: Double(try row.int64(18)) / 1_000
        )
    }

    // MARK: Incoming

    private static let incomingColumns = "id, route, session, descriptor, digest, object, phase, present, attempts, rejection, retry_at"

    func incoming(_ id: Data) throws -> BlobIncomingRow? {
        try database.first("SELECT \(Self.incomingColumns) FROM incoming WHERE id = ?", [.blob(id)], Self.incomingRow)
    }

    func allIncoming() throws -> [BlobIncomingRow] {
        var rows: [BlobIncomingRow] = []
        try database.rows("SELECT \(Self.incomingColumns) FROM incoming ORDER BY id") { rows.append(try Self.incomingRow($0)) }
        return rows
    }

    func put(_ row: BlobIncomingRow) throws {
        try database.run(
            "INSERT OR REPLACE INTO incoming (\(Self.incomingColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                .blob(row.id), .blob(row.route), .blob(row.session), .blob(row.descriptor), .blob(row.digest),
                .blob(row.objectID), .integer(row.phase.rawValue), .integer(Int64(row.present)), .integer(Int64(row.attempts)),
                row.rejection.map { .text($0) } ?? .null, .integer(Int64(row.retryAt * 1_000)),
            ]
        )
    }

    func deleteIncoming(_ id: Data) throws {
        try database.run("DELETE FROM incoming WHERE id = ?", [.blob(id)])
    }

    private static func incomingRow(_ row: JournalRow) throws -> BlobIncomingRow {
        guard let phase = BlobIncomingPhase(rawValue: try row.int64(6)) else { throw BlobError.storageUnavailable }
        return BlobIncomingRow(
            id: try row.blob(0), route: try row.blob(1), session: try row.blob(2), descriptor: try row.blob(3),
            digest: try row.blob(4), objectID: try row.blob(5), phase: phase, present: UInt32(try row.unsigned(7)),
            attempts: Int(try row.int64(8)), rejection: row.isNull(9) ? nil : try row.text(9),
            retryAt: Double(try row.int64(10)) / 1_000
        )
    }

    // MARK: Available registry

    func available(route: Data, objectID: Data) throws -> Data? {
        try database.first("SELECT descriptor FROM available WHERE route = ? AND object = ?", [.blob(route), .blob(objectID)]) {
            try $0.blob(0)
        }
    }

    func availableCount(kind: BlobContentKind? = nil) throws -> Int {
        if let kind {
            let version = kind == .image ? BlobDescriptor.version : BlobDescriptor.dataVersion
            return try database.first("SELECT COUNT(*) FROM available WHERE substr(descriptor, 5, 1) = ?",
                                      [.blob(Data([version]))]) { Int(try $0.int64(0)) } ?? 0
        }
        return try database.first("SELECT COUNT(*) FROM available", []) { Int(try $0.int64(0)) } ?? 0
    }

    func register(route: Data, objectID: Data, descriptor: Data) throws {
        try database.run("INSERT OR REPLACE INTO available (route, object, descriptor) VALUES (?, ?, ?)",
                         [.blob(route), .blob(objectID), .blob(descriptor)])
    }

    func unregister(route: Data, objectID: Data) throws {
        try database.run("DELETE FROM available WHERE route = ? AND object = ?", [.blob(route), .blob(objectID)])
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
