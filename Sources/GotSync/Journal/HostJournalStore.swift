import CryptoKit
import Foundation

enum HostJournalCapacity: Equatable, Sendable {
    case submitBudget
    case history
    case pending
    case quarantine
    case origins
}

enum HostJournalError: Error, Equatable {
    case storage(code: Int32, message: String)
    case valueOutOfRange
    case invalidArgument(String)
    case storeExists
    case storeMissing
    case storeUnreadable(String)
    case formatUnsupported(Int64)
    case storeCorrupt(String)
    case retired
    case notResumed
    case enrollmentRequired
    case staleJournal
    case hostProvenanceMissing
    case hostProvenanceMismatch
    case hostCaptureRegressed
    case hostApplicationRegressed
    case positionOutOfRange(UInt64)
    case payloadTooLarge(Int)
    case hostMutationConflict(Data)
    case capacity(HostJournalCapacity)
    case fork(origin: Data, sequence: UInt64)
    case retainedRecordMissing(origin: Data, sequence: UInt64)
    case foreignOwnOrigin(sequence: UInt64)
    case quarantineConflict(sender: Data, cursor: UInt64)
    case heldInboxConflict(sender: Data, cursor: UInt64)
    case exportCursorMismatch
    case exportRevisionChanged
    case notArchived
    case confirmationMismatch
}

struct HostJournalLimits: Equatable, Sendable {
    var submitBytes: UInt64 = 8 * 1_024 * 1_024
    var submitRecords: UInt64 = 40_000
    /// Records and pending envelopes together.
    var historyBytes: UInt64 = 24 * 1_024 * 1_024
    var historyRecords: UInt64 = 120_000
    /// A part of the history allowance, not an addition to it.
    var pendingBytes: UInt64 = 8 * 1_024 * 1_024
    var pendingRecords: UInt64 = 10_000
    var quarantineBytes: UInt64 = 4 * 1_024 * 1_024
    var quarantineItems: UInt64 = 1_024
    var origins: UInt64 = UInt64(ReplicaLimits.maxOrigins)
    var batch = 256

    static let standard = HostJournalLimits()
}

enum HostJournalEnrollment: Equatable, Sendable {
    case none
    case pending(Data)
    case confirmed(Data)
}

enum HostJournalRetirement: String, Equatable, Sendable {
    case unlink
    case removed
    case orphaned
}

/// What the host saves with its business state and presents on every launch.
struct HostJournalProvenance: Equatable, Sendable {
    let journalID: Data
    let enrollmentID: Data
    /// Last journal position the host committed to its business store; 0 for none.
    let appliedThrough: UInt64
    /// The host's own capture counter, saved with its outbox before submission.
    let capturedThrough: UInt64
}

struct HostJournalMutation: Equatable, Sendable {
    let id: Data
    let payload: Data
}

/// One MLS application message. `envelopes` is nil when its plaintext could
/// not be decoded into record envelopes.
struct HostJournalArrival: Equatable, Sendable {
    let sender: Data
    let cursor: UInt64
    let plaintext: Data
    let envelopes: [Data]?
}

struct HostJournalHeldMessage: Equatable, Sendable {
    let sender: Data
    let cursor: UInt64
    let plaintext: Data
}

struct HostJournalIncoming: Equatable, Sendable {
    let position: UInt64
    let record: JournalRecordID
    let payload: Data
}

/// The leading `ownedArrivals` arrivals are durably owned by the journal and
/// may be acknowledged; the rest stay with their previous owner.
struct HostJournalIntake: Equatable, Sendable {
    let ownedArrivals: Int
    let refusal: HostJournalCapacity?
}

enum HostJournalCommitPoint: Hashable, Sendable {
    case beforeCommit(String)
    case afterCommit(String)
}

/// Committed rows of one journal. It says nothing about engine quiescence.
struct HostJournalCoreView: Equatable, Sendable {
    let journalID: Data
    let group: Data
    let origin: Data
    let retirement: HostJournalRetirement?
    let revision: UInt64
    let enrollment: HostJournalEnrollment
    let capturedThrough: UInt64
    let appliedThrough: UInt64
    let delivered: UInt64
    let ownHead: UInt64
    let recordCount: UInt64
    let recordBytes: UInt64
    let pendingCount: UInt64
    let pendingBytes: UInt64
    let quarantineCount: UInt64
    let quarantineBytes: UInt64
    let heldCount: UInt64
    let heldBytes: UInt64
    let originCount: UInt64
    /// A main checkpoint has referenced this generation.
    let established: Bool
    /// The host declared its initial capture submitted through `readyThrough`.
    let isReady: Bool
    let readyThrough: UInt64
    /// Every record up to the provider's completion target is received; a
    /// founder starts complete with position zero.
    let historyComplete: Bool
    let completionProvider: Data?
    let completionTarget: [Data: UInt64]?
    let completionPosition: UInt64
    let historyProvider: Data?
    /// Control metadata for this generation was lost; admission, completion
    /// and destructive membership cleanup stay blocked.
    let controlRepair: Bool

    var isRetired: Bool { retirement != nil }
    /// The host applied every record of its completed history.
    var historyApplied: Bool { historyComplete && appliedThrough >= completionPosition }
    var undelivered: UInt64 { delivered - appliedThrough }
    var retainedCount: UInt64 { recordCount + pendingCount }
    var retainedBytes: UInt64 { recordBytes + pendingBytes }
}

/// A durable host record journal for one group generation. Every mutation is
/// one SQLite transaction; `view` changes only after its commit succeeds.
@MainActor
final class HostJournalStore {
    static let filePrefix = "host-journal-"
    static let fileSuffix = ".sqlite3"
    static let creatingSuffix = ".creating"
    static let formatVersion: Int64 = 2

    let url: URL
    let limits: HostJournalLimits
    private(set) var view: HostJournalCoreView
    /// Set by a successful `resume` in this process; submission, enumeration
    /// and application require it.
    private(set) var isResumed = false
    var faultHookForTesting: ((HostJournalCommitPoint) throws -> Void)?
    /// Called after every commit, once `view` shows it.
    var committed: (@MainActor () -> Void)?
    private let database: JournalDatabase

    static func fileURL(in directory: URL, journalID: Data) -> URL {
        directory.appendingPathComponent(filePrefix + journalID.map { String(format: "%02x", $0) }.joined() + fileSuffix)
    }

    /// Creates a journal with a random identity and origin. The file appears
    /// under its final name only once completely initialized.
    static func create(
        in directory: URL, group: Data, founder: Bool = false, limits: HostJournalLimits = .standard
    ) throws -> HostJournalStore {
        guard group.count == 32 else {
            throw HostJournalError.invalidArgument("group")
        }
        let journalID = randomBytes(16)
        let url = fileURL(in: directory, journalID: journalID)
        let staging = URL(fileURLWithPath: url.path + creatingSuffix)
        let manager = FileManager.default
        guard !manager.fileExists(atPath: url.path), !manager.fileExists(atPath: staging.path) else {
            throw HostJournalError.storeExists
        }
        do {
            let database = try JournalDatabase(url: staging, readOnly: false, create: true)
            try configure(database)
            try database.execute("BEGIN IMMEDIATE")
            do {
                try createSchema(database, journalID: journalID, group: group, origin: randomBytes(16), founder: founder)
                try database.execute("COMMIT")
            } catch {
                try? database.execute("ROLLBACK")
                throw error
            }
        }
        try protect(staging)
        try manager.moveItem(at: staging, to: url)
        return try open(url, limits: limits)
    }

    /// Opens and fully validates an existing journal. A missing, unreadable,
    /// unsupported or inconsistent file is reported, never recreated.
    ///
    /// The format, journal mode and contents are inspected on a read-only
    /// connection first, so a rejected file is never recovered, checkpointed
    /// or converted. Only a hot rollback journal, which SQLite must roll back
    /// before any read, is recovered on a read-write connection and then
    /// inspected the same way. Write settings apply after inspection succeeds.
    static func open(_ url: URL, limits: HostJournalLimits = .standard) throws -> HostJournalStore {
        try requireRegularFile(url)
        var inspected: HostJournalCoreView?
        do {
            inspected = try inspect(JournalDatabase(url: url, readOnly: true))
        } catch HostJournalError.storage(let code, _) where code == JournalDatabase.hotJournalCode {
            inspected = nil
        } catch HostJournalError.storage(let code, let message) {
            throw HostJournalError.storeUnreadable("\(code): \(message)")
        }
        do {
            let database = try JournalDatabase(url: url, readOnly: false)
            let view = try inspected ?? inspect(database)
            try configure(database)
            return HostJournalStore(url: url, limits: limits, database: database, view: view)
        } catch HostJournalError.storage(let code, let message) {
            throw HostJournalError.storeUnreadable("\(code): \(message)")
        }
    }

    private static func inspect(_ database: JournalDatabase) throws -> HostJournalCoreView {
        try database.execute("BEGIN")
        defer { try? database.execute("COMMIT") }
        try checkFormat(database)
        let mode = try database.first("PRAGMA journal_mode", [], { try $0.text(0) }) ?? ""
        guard mode == "delete" else {
            throw HostJournalError.storeCorrupt("journal mode \(mode)")
        }
        return try validate(database)
    }

    private init(url: URL, limits: HostJournalLimits, database: JournalDatabase, view: HostJournalCoreView) {
        self.url = url
        self.limits = limits
        self.database = database
        self.view = view
    }

    // MARK: - Enrollment

    /// Starts an enrollment that the host confirms with `resume` after saving
    /// the returned provenance. Refused once an enrollment was confirmed,
    /// whether or not any record exists.
    func enroll() throws -> HostJournalProvenance {
        try transaction("enroll") {
            let meta = try readMeta()
            guard meta.retirement == nil else { throw HostJournalError.retired }
            if case .confirmed = meta.enrollment { throw HostJournalError.hostProvenanceMissing }
            let enrollmentID = Self.randomBytes(16)
            try setMeta("enrollment", .text("pending"))
            try setMeta("enrollmentID", .blob(enrollmentID))
            try bumpRevision(meta)
            isResumed = false
            return HostJournalProvenance(
                journalID: meta.journalID, enrollmentID: enrollmentID, appliedThrough: 0, capturedThrough: 0
            )
        }
    }

    /// Confirms a pending enrollment or checks a confirmed one against the
    /// host's saved provenance. A host behind what the library recorded stops;
    /// a host ahead in application advances the library.
    func resume(_ stored: HostJournalProvenance) throws -> HostJournalProvenance {
        let result = try transaction("resume") { () -> HostJournalProvenance in
            let meta = try readMeta()
            guard stored.journalID == meta.journalID else { throw HostJournalError.staleJournal }
            guard meta.retirement == nil else { throw HostJournalError.retired }
            switch meta.enrollment {
            case .none:
                throw HostJournalError.enrollmentRequired
            case .pending(let enrollmentID):
                guard stored.enrollmentID == enrollmentID, stored.appliedThrough == 0 else {
                    throw HostJournalError.hostProvenanceMismatch
                }
                try setMeta("enrollment", .text("confirmed"))
                try bumpRevision(meta)
                return HostJournalProvenance(
                    journalID: meta.journalID, enrollmentID: enrollmentID,
                    appliedThrough: 0, capturedThrough: stored.capturedThrough
                )
            case .confirmed(let enrollmentID):
                guard stored.enrollmentID == enrollmentID else { throw HostJournalError.hostProvenanceMismatch }
                guard stored.capturedThrough >= meta.capturedThrough else { throw HostJournalError.hostCaptureRegressed }
                guard stored.appliedThrough >= meta.appliedThrough else { throw HostJournalError.hostApplicationRegressed }
                guard stored.appliedThrough < meta.nextPosition else {
                    throw HostJournalError.positionOutOfRange(stored.appliedThrough)
                }
                if stored.appliedThrough > meta.appliedThrough {
                    try applyThrough(stored.appliedThrough, from: meta.appliedThrough)
                    try bumpRevision(meta)
                }
                return HostJournalProvenance(
                    journalID: meta.journalID, enrollmentID: enrollmentID,
                    appliedThrough: stored.appliedThrough, capturedThrough: stored.capturedThrough
                )
            }
        }
        isResumed = true
        return result
    }

    // MARK: - Submission

    /// Assigns the next own sequences to new mutation IDs and returns the
    /// existing record for a repeated ID with identical payload bytes. The
    /// batch is all or nothing. `capturedThrough` is the host's capture
    /// counter as saved before this call.
    func submit(_ batch: [HostJournalMutation], capturedThrough: UInt64) throws -> [JournalRecordID] {
        guard !batch.isEmpty, batch.count <= limits.batch else { throw HostJournalError.invalidArgument("batch") }
        for mutation in batch {
            guard mutation.id.count == 16 else { throw HostJournalError.invalidArgument("mutation id") }
            guard mutation.payload.count <= JournalEnvelope.maxPayloadLength else {
                throw HostJournalError.payloadTooLarge(mutation.payload.count)
            }
        }
        try requireResumed()
        _ = try JournalDatabase.integer(capturedThrough)
        return try transaction("submit") {
            let meta = try readMeta()
            guard meta.retirement == nil else { throw HostJournalError.retired }
            guard case .confirmed = meta.enrollment else { throw HostJournalError.enrollmentRequired }
            guard capturedThrough >= meta.capturedThrough else { throw HostJournalError.hostCaptureRegressed }
            var counters = meta.counters
            var ownHead = meta.ownHead
            var records: [JournalRecordID] = []
            for mutation in batch {
                let payloadDigest = Data(SHA256.hash(data: mutation.payload))
                if let existing = try database.first(
                    "SELECT sequence, payloadDigest FROM submissions WHERE id = ?", [.blob(mutation.id)],
                    { (try $0.unsigned(0), try $0.blob(1)) }
                ) {
                    guard existing.1 == payloadDigest else { throw HostJournalError.hostMutationConflict(mutation.id) }
                    records.append(JournalRecordID(origin: meta.origin, sequence: existing.0))
                    continue
                }
                let head = try originHead(meta.origin)
                guard head.received == ownHead else { throw HostJournalError.storeCorrupt("own head") }
                let envelope = try JournalEnvelope(
                    origin: meta.origin, sequence: ownHead + 1, prior: head.digest, payload: mutation.payload
                )
                let length = UInt64(envelope.bytes.count)
                guard counters.retainedCount + 1 <= limits.submitRecords,
                      counters.retainedBytes + length <= limits.submitBytes
                else { throw HostJournalError.capacity(.submitBudget) }
                try insertRecord(envelope, position: nil)
                try database.run(
                    "INSERT INTO submissions(id, sequence, payloadDigest) VALUES (?, ?, ?)",
                    [.blob(mutation.id), try JournalDatabase.integer(envelope.sequence), .blob(payloadDigest)]
                )
                ownHead = envelope.sequence
                counters.recordCount += 1
                counters.recordBytes += length
                records.append(envelope.id)
            }
            try setMeta("ownHead", try JournalDatabase.integer(ownHead))
            try setMeta("capturedThrough", try JournalDatabase.integer(max(capturedThrough, meta.capturedThrough)))
            try writeCounters(counters)
            try bumpRevision(meta)
            return records
        }
    }

    // MARK: - Intake

    /// Takes ownership of arrivals in order. Every envelope of every arrival is
    /// checked against retained, pending and other incoming records before
    /// anything is written; a conflict stops the whole call with no write. An
    /// arrival is owned completely or not at all, and intake stops at the
    /// first one that does not fit.
    func intake(_ arrivals: [HostJournalArrival]) throws -> HostJournalIntake {
        for arrival in arrivals {
            guard arrival.sender.count == 32 else { throw HostJournalError.invalidArgument("sender") }
            _ = try JournalDatabase.integer(arrival.cursor)
        }
        guard !arrivals.isEmpty else { return HostJournalIntake(ownedArrivals: 0, refusal: nil) }
        do {
            return try intakeTransaction(arrivals)
        } catch let refused as NothingOwned {
            return HostJournalIntake(ownedArrivals: 0, refusal: refused.refusal)
        }
    }

    /// Rolls back an intake that owns no arrival, so a refusal leaves the file untouched.
    private struct NothingOwned: Error {
        let refusal: HostJournalCapacity?
    }

    private func intakeTransaction(_ arrivals: [HostJournalArrival]) throws -> HostJournalIntake {
        try transaction("intake") {
            let meta = try readMeta()
            guard meta.retirement == nil else { throw HostJournalError.retired }
            let parsed = arrivals.map(Self.parse)
            try preflight(parsed, meta: meta)
            var counters = meta.counters
            var nextPosition = meta.nextPosition
            var owned = 0
            var refusal: HostJournalCapacity?
            for (arrival, envelopes) in zip(arrivals, parsed) {
                try database.execute("SAVEPOINT arrival")
                let before = (counters, nextPosition)
                if let envelopes {
                    for envelope in envelopes {
                        try accept(envelope, meta: meta, counters: &counters, nextPosition: &nextPosition)
                    }
                } else {
                    try quarantine(arrival, counters: &counters)
                }
                if let exceeded = try exceededLimit(counters) {
                    try database.execute("ROLLBACK TO arrival")
                    try database.execute("RELEASE arrival")
                    (counters, nextPosition) = before
                    refusal = exceeded
                    break
                }
                try database.execute("RELEASE arrival")
                owned += 1
            }
            guard owned > 0 else { throw NothingOwned(refusal: refusal) }
            try setMeta("nextPosition", try JournalDatabase.integer(nextPosition))
            try writeCounters(counters)
            if !meta.historyComplete, let target = meta.completionTarget {
                try evaluateCompletion(target)
            }
            try bumpRevision(meta)
            return HostJournalIntake(ownedArrivals: owned, refusal: refusal)
        }
    }

    private static func parse(_ arrival: HostJournalArrival) -> [JournalEnvelope]? {
        guard let raw = arrival.envelopes, !raw.isEmpty else { return nil }
        var envelopes: [JournalEnvelope] = []
        for bytes in raw {
            guard let envelope = try? JournalEnvelope(parsing: bytes) else { return nil }
            if let last = envelopes.last {
                let ordered = last.origin.lexicographicallyPrecedes(envelope.origin)
                    || (last.origin == envelope.origin && last.sequence < envelope.sequence)
                guard ordered else { return nil }
            }
            envelopes.append(envelope)
        }
        return envelopes
    }

    private func preflight(_ parsed: [[JournalEnvelope]?], meta: Meta) throws {
        var incoming: [JournalRecordID: JournalEnvelope] = [:]
        var origins: Set<Data> = []
        var heads: [Data: (received: UInt64, digest: Data)] = [:]
        func originHead(_ origin: Data) throws -> (received: UInt64, digest: Data) {
            if let head = heads[origin] { return head }
            let head = try self.originHead(origin)
            heads[origin] = head
            return head
        }
        let hasPending = meta.counters.pendingCount > 0
        func pendingEnvelope(_ id: JournalRecordID) throws -> JournalEnvelope? {
            hasPending ? try self.pendingEnvelope(id) : nil
        }
        for envelope in parsed.compactMap({ $0 }).joined() {
            if let earlier = incoming[envelope.id] {
                guard earlier.digest == envelope.digest else {
                    throw HostJournalError.fork(origin: envelope.origin, sequence: envelope.sequence)
                }
                continue
            }
            incoming[envelope.id] = envelope
            let received = try originHead(envelope.origin).received
            if envelope.origin == meta.origin, envelope.sequence > meta.ownHead {
                throw HostJournalError.foreignOwnOrigin(sequence: envelope.sequence)
            }
            if envelope.sequence <= received {
                guard let retained = try retainedDigest(envelope.id) else {
                    throw HostJournalError.retainedRecordMissing(origin: envelope.origin, sequence: envelope.sequence)
                }
                guard retained == envelope.digest else {
                    throw HostJournalError.fork(origin: envelope.origin, sequence: envelope.sequence)
                }
            } else {
                if let pending = try pendingEnvelope(envelope.id), pending.digest != envelope.digest {
                    throw HostJournalError.fork(origin: envelope.origin, sequence: envelope.sequence)
                }
                origins.insert(envelope.origin)
            }
        }
        for origin in origins {
            var head = try originHead(origin)
            var sequence = head.received + 1
            while true {
                let candidate = try incoming[JournalRecordID(origin: origin, sequence: sequence)]
                    ?? pendingEnvelope(JournalRecordID(origin: origin, sequence: sequence))
                guard let candidate else { break }
                guard candidate.prior == head.digest else {
                    throw HostJournalError.fork(origin: origin, sequence: sequence)
                }
                head = (sequence, candidate.digest)
                sequence += 1
            }
        }
    }

    private func accept(
        _ envelope: JournalEnvelope,
        meta: Meta,
        counters: inout Counters,
        nextPosition: inout UInt64
    ) throws {
        if envelope.origin == meta.origin {
            return
        }
        try ensureOrigin(envelope.origin, counters: &counters)
        var head = try originHead(envelope.origin)
        guard envelope.sequence > head.received else {
            return
        }
        guard try pendingEnvelope(envelope.id) == nil else {
            return
        }
        guard envelope.sequence == head.received + 1 else {
            try database.run(
                "INSERT INTO pending(origin, sequence, envelope, digest) VALUES (?, ?, ?, ?)",
                [.blob(envelope.origin), try JournalDatabase.integer(envelope.sequence), .blob(envelope.bytes), .blob(envelope.digest)]
            )
            counters.pendingCount += 1
            counters.pendingBytes += UInt64(envelope.bytes.count)
            return
        }
        var next: JournalEnvelope? = envelope
        while let record = next {
            guard record.prior == head.digest else {
                throw HostJournalError.fork(origin: record.origin, sequence: record.sequence)
            }
            try insertRecord(record, position: nextPosition)
            nextPosition += 1
            counters.recordCount += 1
            counters.recordBytes += UInt64(record.bytes.count)
            head = (record.sequence, record.digest)
            let following = JournalRecordID(origin: record.origin, sequence: record.sequence + 1)
            next = try pendingEnvelope(following)
            if let promoted = next {
                try database.run(
                    "DELETE FROM pending WHERE origin = ? AND sequence = ?",
                    [.blob(promoted.origin), try JournalDatabase.integer(promoted.sequence)]
                )
                counters.pendingCount -= 1
                counters.pendingBytes -= UInt64(promoted.bytes.count)
            }
        }
    }

    private func quarantine(_ arrival: HostJournalArrival, counters: inout Counters) throws {
        let digest = Data(SHA256.hash(data: arrival.plaintext))
        let key: [JournalValue] = [.blob(arrival.sender), try JournalDatabase.integer(arrival.cursor)]
        if let existing = try database.first(
            "SELECT digest FROM quarantine WHERE sender = ? AND cursor = ?", key, { try $0.blob(0) }
        ) {
            guard existing == digest else {
                throw HostJournalError.quarantineConflict(sender: arrival.sender, cursor: arrival.cursor)
            }
            return
        }
        try database.run(
            "INSERT INTO quarantine(sender, cursor, reason, bytes, digest) VALUES (?, ?, ?, ?, ?)",
            key + [.text(arrival.envelopes == nil ? "undecodable" : "malformedEnvelopes"), .blob(arrival.plaintext), .blob(digest)]
        )
        counters.quarantineCount += 1
        counters.quarantineBytes += UInt64(arrival.plaintext.count)
    }

    private func exceededLimit(_ counters: Counters) throws -> HostJournalCapacity? {
        if counters.retainedCount > limits.historyRecords || counters.retainedBytes > limits.historyBytes {
            return .history
        }
        if counters.pendingCount > limits.pendingRecords || counters.pendingBytes > limits.pendingBytes {
            return .pending
        }
        if counters.quarantineCount > limits.quarantineItems || counters.quarantineBytes > limits.quarantineBytes {
            return .quarantine
        }
        if counters.originCount > limits.origins {
            return .origins
        }
        return nil
    }

    // MARK: - Application

    /// Remote records after `position`, in position order.
    func incoming(after position: UInt64, limit: Int) throws -> [HostJournalIncoming] {
        try requireResumed()
        guard limit > 0, limit <= limits.batch else { throw HostJournalError.invalidArgument("limit") }
        var result: [HostJournalIncoming] = []
        try database.rows(
            "SELECT position, envelope FROM records WHERE position > ? ORDER BY position LIMIT ?",
            [try JournalDatabase.integer(position), .integer(Int64(limit))]
        ) { row in
            let envelope = try Self.stored(try row.blob(1))
            result.append(HostJournalIncoming(position: try row.unsigned(0), record: envelope.id, payload: envelope.payload))
        }
        return result
    }

    /// Records that the host committed its business state through `position`.
    func markApplied(through position: UInt64) throws {
        try requireResumed()
        _ = try JournalDatabase.integer(position)
        try transaction("markApplied") {
            let meta = try readMeta()
            guard meta.retirement == nil else { throw HostJournalError.retired }
            guard position < meta.nextPosition else { throw HostJournalError.positionOutOfRange(position) }
            guard position > meta.appliedThrough else { return }
            try applyThrough(position, from: meta.appliedThrough)
            try bumpRevision(meta)
        }
    }

    /// Positions of one origin rise with its sequences, so only origins with
    /// records in the newly applied range change.
    private func applyThrough(_ position: UInt64, from previous: UInt64) throws {
        let bounds = [try JournalDatabase.integer(previous), try JournalDatabase.integer(position)]
        try setMeta("appliedThrough", bounds[1])
        try database.run(
            """
            UPDATE origins SET applied = advanced.sequence FROM (SELECT origin, MAX(sequence) AS sequence FROM records
                WHERE position > ? AND position <= ? GROUP BY origin) AS advanced
            WHERE origins.origin = advanced.origin
            """,
            bounds
        )
    }

    // MARK: - Engine reads

    /// The highest contiguous sequence held for every origin, the own origin
    /// at its head.
    func receivedVector() throws -> [Data: UInt64] {
        var vector: [Data: UInt64] = [:]
        try database.rows("SELECT origin, received FROM origins WHERE received > 0") {
            vector[try $0.blob(0)] = try $0.unsigned(1)
        }
        return vector
    }

    /// Origins this journal holds rows or pending records for, the own origin included.
    func origins() throws -> [Data] {
        var origins: [Data] = []
        try database.rows("SELECT origin FROM origins ORDER BY origin") { origins.append(try $0.blob(0)) }
        return origins
    }

    /// Retained records above `missingFrom` and, when given, at or below
    /// `through`, in origin and sequence order, until a bound is reached.
    func records(
        missingFrom vector: [Data: UInt64], through cut: [Data: UInt64]?, maxBytes: Int, maxCount: Int
    ) throws -> [JournalEnvelope] {
        var result: [JournalEnvelope] = []
        var bytes = 0
        for origin in try origins() {
            let floor = vector[origin] ?? 0
            let ceiling = cut.map { $0[origin] ?? 0 } ?? JournalEnvelope.maxSequence
            guard ceiling > floor else { continue }
            var full = false
            try database.rows(
                "SELECT envelope FROM records WHERE origin = ? AND sequence > ? AND sequence <= ? ORDER BY sequence LIMIT ?",
                [.blob(origin), try JournalDatabase.integer(floor), try JournalDatabase.integer(ceiling), .integer(Int64(maxCount - result.count))]
            ) { row in
                guard !full else { return }
                let envelope = try Self.stored(try row.blob(0))
                guard bytes + envelope.bytes.count <= maxBytes || result.isEmpty else {
                    full = true
                    return
                }
                bytes += envelope.bytes.count
                result.append(envelope)
            }
            if full || result.count >= maxCount { break }
        }
        return result
    }

    /// Own records after `sequence`, in order, until a bound is reached.
    func ownRecords(after sequence: UInt64, maxBytes: Int, maxCount: Int) throws -> [JournalEnvelope] {
        try records(missingFrom: [view.origin: sequence], through: [view.origin: JournalEnvelope.maxSequence], maxBytes: maxBytes, maxCount: maxCount)
    }

    /// Runs the intake fork, predecessor and own-origin checks over a whole
    /// window without writing anything.
    func verify(_ arrivals: [HostJournalArrival]) throws {
        for arrival in arrivals {
            guard arrival.sender.count == 32 else { throw HostJournalError.invalidArgument("sender") }
            _ = try JournalDatabase.integer(arrival.cursor)
        }
        try database.execute("BEGIN")
        defer { try? database.execute("COMMIT") }
        try preflight(arrivals.map(Self.parse), meta: try readMeta())
    }

    // MARK: - Engine state

    /// Records that a main checkpoint references this generation.
    func markEstablished() throws {
        try transaction("markEstablished") {
            let meta = try readMeta()
            guard meta.retirement == nil else { throw HostJournalError.retired }
            guard !meta.established else { return }
            try setMeta("established", .integer(1))
            try bumpRevision(meta)
        }
    }

    /// The host has captured and submitted all of its preexisting content
    /// through its capture counter `capturedThrough`.
    func declareReady(capturedThrough: UInt64) throws {
        try requireResumed()
        _ = try JournalDatabase.integer(capturedThrough)
        try transaction("declareReady") {
            let meta = try readMeta()
            guard meta.retirement == nil else { throw HostJournalError.retired }
            guard case .confirmed = meta.enrollment else { throw HostJournalError.enrollmentRequired }
            guard meta.capturedThrough >= capturedThrough else { throw HostJournalError.hostCaptureRegressed }
            guard !meta.isReady || capturedThrough > meta.readyThrough else { return }
            try setMeta("ready", .integer(1))
            try setMeta("readyThrough", try JournalDatabase.integer(max(capturedThrough, meta.readyThrough)))
            try bumpRevision(meta)
        }
    }

    /// Stores a provider's completion target. A target lower than the stored
    /// one in any origin, or any target after completion, is ignored.
    @discardableResult
    func recordCompletionTarget(provider: Data, through target: [Data: UInt64]) throws -> Bool {
        guard provider.count == 32 else { throw HostJournalError.invalidArgument("provider") }
        let encoded = try Self.encodeVector(target)
        return try transaction("recordCompletionTarget") {
            let meta = try readMeta()
            guard meta.retirement == nil else { throw HostJournalError.retired }
            guard !meta.historyComplete else { return false }
            if let stored = meta.completionTarget {
                guard stored.allSatisfy({ target[$0.key] ?? 0 >= $0.value }) else { return false }
            }
            try setMeta("completionProvider", .blob(provider))
            try setMeta("completionTarget", .blob(encoded))
            try evaluateCompletion(target)
            try bumpRevision(meta)
            return true
        }
    }

    func setHistoryProvider(_ member: Data) throws {
        guard member.count == 32 else { throw HostJournalError.invalidArgument("provider") }
        try transaction("setHistoryProvider") {
            let meta = try readMeta()
            guard meta.retirement == nil else { throw HostJournalError.retired }
            guard meta.historyProvider != member else { return }
            try setMeta("historyProvider", .blob(member))
            try bumpRevision(meta)
        }
    }

    /// Marks lost control metadata. Only a verified recovery, not part of
    /// this core, may clear it.
    func enterControlRepair() throws {
        try transaction("enterControlRepair") {
            let meta = try readMeta()
            guard !meta.controlRepair else { return }
            try setMeta("controlRepair", .integer(1))
            try bumpRevision(meta)
        }
    }

    /// Completes the history when every origin of the target is received,
    /// at the highest position of the records it covers.
    private func evaluateCompletion(_ target: [Data: UInt64]) throws {
        var position: UInt64 = 0
        for (origin, sequence) in target {
            guard try originHead(origin).received >= sequence else { return }
            if let covered = try database.first(
                "SELECT MAX(position) FROM records WHERE origin = ? AND sequence <= ? AND position IS NOT NULL",
                [.blob(origin), try JournalDatabase.integer(sequence)], { $0.isNull(0) ? nil : try $0.unsigned(0) }
            ) ?? nil {
                position = max(position, covered)
            }
        }
        try setMeta("historyComplete", .integer(1))
        try setMeta("completionPosition", try JournalDatabase.integer(position))
    }

    static func encodeVector(_ vector: [Data: UInt64]) throws -> Data {
        var data = Data()
        for (origin, sequence) in vector.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
            guard origin.count == JournalEnvelope.originLength, sequence >= 1, sequence <= JournalEnvelope.maxSequence else {
                throw HostJournalError.invalidArgument("vector")
            }
            data.append(origin)
            withUnsafeBytes(of: sequence.bigEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decodeVector(_ data: Data) throws -> [Data: UInt64] {
        let entry = JournalEnvelope.originLength + 8
        guard data.count % entry == 0, data.count / entry <= 1_024 else { throw HostJournalError.storeCorrupt("vector") }
        let bytes = Data(data)
        var vector: [Data: UInt64] = [:]
        var previous: Data?
        for offset in stride(from: 0, to: bytes.count, by: entry) {
            let origin = bytes.subdata(in: offset..<offset + JournalEnvelope.originLength)
            let sequence = bytes.subdata(in: offset + JournalEnvelope.originLength..<offset + entry).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            guard sequence >= 1, sequence <= JournalEnvelope.maxSequence,
                  previous.map({ $0.lexicographicallyPrecedes(origin) }) ?? true
            else { throw HostJournalError.storeCorrupt("vector") }
            vector[origin] = sequence
            previous = origin
        }
        return vector
    }

    // MARK: - Retirement

    /// Copies the frozen inbox snapshot and marks the journal retired in one
    /// transaction. On failure nothing changes and the caller keeps its
    /// original owner. A repeated sender and cursor must carry identical bytes.
    func retire(_ reason: HostJournalRetirement, heldInbox: [HostJournalHeldMessage]) throws {
        for message in heldInbox {
            guard message.sender.count == 32 else { throw HostJournalError.invalidArgument("sender") }
            _ = try JournalDatabase.integer(message.cursor)
        }
        try transaction("retire") {
            let meta = try readMeta()
            guard meta.retirement == nil else { throw HostJournalError.retired }
            var counters = meta.counters
            for message in heldInbox {
                let digest = Data(SHA256.hash(data: message.plaintext))
                let key: [JournalValue] = [.blob(message.sender), try JournalDatabase.integer(message.cursor)]
                if let existing = try database.first(
                    "SELECT digest FROM heldInbox WHERE sender = ? AND cursor = ?", key, { try $0.blob(0) }
                ) {
                    guard existing == digest else {
                        throw HostJournalError.heldInboxConflict(sender: message.sender, cursor: message.cursor)
                    }
                    continue
                }
                try database.run(
                    "INSERT INTO heldInbox(sender, cursor, plaintext, digest) VALUES (?, ?, ?, ?)",
                    key + [.blob(message.plaintext), .blob(digest)]
                )
                counters.heldCount += 1
                counters.heldBytes += UInt64(message.plaintext.count)
            }
            try writeCounters(counters)
            try setMeta("retirement", .text(reason.rawValue))
            try bumpRevision(meta)
        }
        isResumed = false
    }

    private func requireResumed() throws {
        guard isResumed else { throw view.isRetired ? HostJournalError.retired : HostJournalError.notResumed }
    }

    // MARK: - Transactions

    private func transaction<T>(_ name: String, _ body: () throws -> T) throws -> T {
        try database.execute("BEGIN IMMEDIATE")
        let result: T
        let committed: HostJournalCoreView
        do {
            result = try body()
            committed = try readMeta().view
            try faultHookForTesting?(.beforeCommit(name))
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
        view = committed
        self.committed?()
        try faultHookForTesting?(.afterCommit(name))
        return result
    }

    private func bumpRevision(_ meta: Meta) throws {
        try setMeta("revision", try JournalDatabase.integer(meta.revision + 1))
    }

    private func setMeta(_ key: String, _ value: JournalValue) throws {
        try database.run("UPDATE meta SET value = ? WHERE key = ?", [value, .text(key)])
    }

    private func writeCounters(_ counters: Counters) throws {
        for (key, value) in counters.fields {
            try setMeta(key, try JournalDatabase.integer(value))
        }
    }

    private func originHead(_ origin: Data) throws -> (received: UInt64, digest: Data) {
        try database.first(
            "SELECT received, head FROM origins WHERE origin = ?", [.blob(origin)],
            { (try $0.unsigned(0), try $0.blob(1)) }
        ) ?? (0, JournalEnvelope.zeroDigest)
    }

    private func ensureOrigin(_ origin: Data, counters: inout Counters) throws {
        let inserted = try database.run(
            "INSERT OR IGNORE INTO origins(origin, received, head, applied) VALUES (?, 0, ?, 0)",
            [.blob(origin), .blob(JournalEnvelope.zeroDigest)]
        )
        counters.originCount += UInt64(inserted)
    }

    private func retainedDigest(_ id: JournalRecordID) throws -> Data? {
        try database.first(
            "SELECT digest FROM records WHERE origin = ? AND sequence = ?",
            [.blob(id.origin), try JournalDatabase.integer(id.sequence)], { try $0.blob(0) }
        )
    }

    private func pendingEnvelope(_ id: JournalRecordID) throws -> JournalEnvelope? {
        guard id.sequence <= JournalEnvelope.maxSequence else { return nil }
        return try database.first(
            "SELECT envelope FROM pending WHERE origin = ? AND sequence = ?",
            [.blob(id.origin), try JournalDatabase.integer(id.sequence)], { try Self.stored(try $0.blob(0)) }
        )
    }

    private func insertRecord(_ envelope: JournalEnvelope, position: UInt64?) throws {
        try database.run(
            "INSERT INTO records(origin, sequence, envelope, digest, position) VALUES (?, ?, ?, ?, ?)",
            [
                .blob(envelope.origin), try JournalDatabase.integer(envelope.sequence), .blob(envelope.bytes),
                .blob(envelope.digest), try position.map(JournalDatabase.integer) ?? .null,
            ]
        )
        try database.run(
            "UPDATE origins SET received = ?, head = ? WHERE origin = ?",
            [try JournalDatabase.integer(envelope.sequence), .blob(envelope.digest), .blob(envelope.origin)]
        )
    }

    private func readMeta() throws -> Meta {
        try Self.readMeta(database)
    }

    // MARK: - Schema and validation

    struct Counters: Equatable {
        var recordCount: UInt64 = 0
        var recordBytes: UInt64 = 0
        var pendingCount: UInt64 = 0
        var pendingBytes: UInt64 = 0
        var quarantineCount: UInt64 = 0
        var quarantineBytes: UInt64 = 0
        var heldCount: UInt64 = 0
        var heldBytes: UInt64 = 0
        var originCount: UInt64 = 0

        var retainedCount: UInt64 { recordCount + pendingCount }
        var retainedBytes: UInt64 { recordBytes + pendingBytes }

        static let keys = [
            "recordCount", "recordBytes", "pendingCount", "pendingBytes", "quarantineCount",
            "quarantineBytes", "heldCount", "heldBytes", "originCount",
        ]

        var fields: [(String, UInt64)] {
            zip(Self.keys, [
                recordCount, recordBytes, pendingCount, pendingBytes, quarantineCount,
                quarantineBytes, heldCount, heldBytes, originCount,
            ]).map { ($0, $1) }
        }

        init() {}

        init(_ values: [String: UInt64]) throws {
            func value(_ key: String) throws -> UInt64 {
                guard let value = values[key] else { throw HostJournalError.storeCorrupt("missing \(key)") }
                return value
            }
            recordCount = try value("recordCount")
            recordBytes = try value("recordBytes")
            pendingCount = try value("pendingCount")
            pendingBytes = try value("pendingBytes")
            quarantineCount = try value("quarantineCount")
            quarantineBytes = try value("quarantineBytes")
            heldCount = try value("heldCount")
            heldBytes = try value("heldBytes")
            originCount = try value("originCount")
        }
    }

    struct Meta {
        let journalID: Data
        let group: Data
        let origin: Data
        let retirement: HostJournalRetirement?
        let revision: UInt64
        let enrollment: HostJournalEnrollment
        let capturedThrough: UInt64
        let appliedThrough: UInt64
        let nextPosition: UInt64
        let ownHead: UInt64
        let counters: Counters
        let established: Bool
        let isReady: Bool
        let readyThrough: UInt64
        let historyComplete: Bool
        let completionProvider: Data?
        let completionTarget: [Data: UInt64]?
        let completionPosition: UInt64
        let historyProvider: Data?
        let controlRepair: Bool

        var view: HostJournalCoreView {
            HostJournalCoreView(
                journalID: journalID, group: group, origin: origin, retirement: retirement, revision: revision,
                enrollment: enrollment, capturedThrough: capturedThrough, appliedThrough: appliedThrough,
                delivered: nextPosition - 1, ownHead: ownHead,
                recordCount: counters.recordCount, recordBytes: counters.recordBytes,
                pendingCount: counters.pendingCount, pendingBytes: counters.pendingBytes,
                quarantineCount: counters.quarantineCount, quarantineBytes: counters.quarantineBytes,
                heldCount: counters.heldCount, heldBytes: counters.heldBytes, originCount: counters.originCount,
                established: established, isReady: isReady, readyThrough: readyThrough,
                historyComplete: historyComplete, completionProvider: completionProvider,
                completionTarget: completionTarget, completionPosition: completionPosition,
                historyProvider: historyProvider, controlRepair: controlRepair
            )
        }
    }

    static func readMeta(_ database: JournalDatabase) throws -> Meta {
        var blobs: [String: Data] = [:]
        var texts: [String: String] = [:]
        var integers: [String: UInt64] = [:]
        try database.rows("SELECT key, value, typeof(value) FROM meta") { row in
            let key = try row.text(0)
            switch try row.text(2) {
            case "blob": blobs[key] = try row.blob(1)
            case "text": texts[key] = try row.text(1)
            case "integer": integers[key] = try row.unsigned(1)
            default: throw HostJournalError.storeCorrupt("meta \(key)")
            }
        }
        func blob(_ key: String, _ length: Int?) throws -> Data {
            guard let value = blobs[key], length.map({ value.count == $0 }) ?? true else {
                throw HostJournalError.storeCorrupt("meta \(key)")
            }
            return value
        }
        func integer(_ key: String) throws -> UInt64 {
            guard let value = integers[key] else { throw HostJournalError.storeCorrupt("meta \(key)") }
            return value
        }
        let retirement: HostJournalRetirement?
        switch texts["retirement"] {
        case "active": retirement = nil
        case .some(let raw):
            guard let reason = HostJournalRetirement(rawValue: raw) else { throw HostJournalError.storeCorrupt("retirement") }
            retirement = reason
        case nil: throw HostJournalError.storeCorrupt("retirement")
        }
        let enrollmentID = try blob("enrollmentID", nil)
        let enrollment: HostJournalEnrollment
        switch texts["enrollment"] {
        case "none" where enrollmentID.isEmpty: enrollment = .none
        case "pending" where enrollmentID.count == 16: enrollment = .pending(enrollmentID)
        case "confirmed" where enrollmentID.count == 16: enrollment = .confirmed(enrollmentID)
        default: throw HostJournalError.storeCorrupt("enrollment")
        }
        let nextPosition = try integer("nextPosition")
        let appliedThrough = try integer("appliedThrough")
        let completionPosition = try integer("completionPosition")
        guard nextPosition >= 1, appliedThrough < nextPosition, completionPosition < nextPosition else {
            throw HostJournalError.storeCorrupt("positions")
        }
        func flag(_ key: String) throws -> Bool {
            switch try integer(key) {
            case 0: return false
            case 1: return true
            default: throw HostJournalError.storeCorrupt("meta \(key)")
            }
        }
        func member(_ key: String) throws -> Data? {
            let value = try blob(key, nil)
            guard value.isEmpty || value.count == 32 else { throw HostJournalError.storeCorrupt("meta \(key)") }
            return value.isEmpty ? nil : value
        }
        let target = try blob("completionTarget", nil)
        let historyComplete = try flag("historyComplete")
        return Meta(
            journalID: try blob("journalID", 16), group: try blob("group", 32), origin: try blob("origin", 16),
            retirement: retirement, revision: try integer("revision"), enrollment: enrollment,
            capturedThrough: try integer("capturedThrough"), appliedThrough: appliedThrough,
            nextPosition: nextPosition, ownHead: try integer("ownHead"), counters: try Counters(integers),
            established: try flag("established"), isReady: try flag("ready"), readyThrough: try integer("readyThrough"),
            historyComplete: historyComplete, completionProvider: try member("completionProvider"),
            completionTarget: target.isEmpty ? nil : try decodeVector(target),
            completionPosition: completionPosition, historyProvider: try member("historyProvider"),
            controlRepair: try flag("controlRepair")
        )
    }

    private static func configure(_ database: JournalDatabase) throws {
        try database.execute("PRAGMA journal_mode=DELETE")
        try database.execute("PRAGMA synchronous=FULL")
        try database.execute("PRAGMA fullfsync=ON")
        try database.execute("PRAGMA secure_delete=ON")
    }

    private static func createSchema(
        _ database: JournalDatabase, journalID: Data, group: Data, origin: Data, founder: Bool
    ) throws {
        try database.execute("""
            CREATE TABLE meta(key TEXT PRIMARY KEY, value ANY NOT NULL) STRICT;
            CREATE TABLE origins(origin BLOB PRIMARY KEY, received INTEGER NOT NULL, head BLOB NOT NULL,
                applied INTEGER NOT NULL) STRICT;
            CREATE TABLE records(origin BLOB NOT NULL, sequence INTEGER NOT NULL, envelope BLOB NOT NULL,
                digest BLOB NOT NULL, position INTEGER UNIQUE, PRIMARY KEY(origin, sequence)) STRICT;
            CREATE TABLE submissions(id BLOB PRIMARY KEY, sequence INTEGER NOT NULL UNIQUE,
                payloadDigest BLOB NOT NULL) STRICT;
            CREATE TABLE pending(origin BLOB NOT NULL, sequence INTEGER NOT NULL, envelope BLOB NOT NULL,
                digest BLOB NOT NULL, PRIMARY KEY(origin, sequence)) STRICT;
            CREATE TABLE quarantine(sender BLOB NOT NULL, cursor INTEGER NOT NULL, reason TEXT NOT NULL,
                bytes BLOB NOT NULL, digest BLOB NOT NULL, PRIMARY KEY(sender, cursor)) STRICT;
            CREATE TABLE heldInbox(sender BLOB NOT NULL, cursor INTEGER NOT NULL, plaintext BLOB NOT NULL,
                digest BLOB NOT NULL, PRIMARY KEY(sender, cursor)) STRICT;
            PRAGMA user_version = \(formatVersion);
            """)
        var values: [(String, JournalValue)] = [
            ("journalID", .blob(journalID)), ("group", .blob(group)), ("origin", .blob(origin)),
            ("retirement", .text("active")), ("revision", .integer(1)), ("enrollment", .text("none")),
            ("enrollmentID", .blob(Data())), ("capturedThrough", .integer(0)), ("appliedThrough", .integer(0)),
            ("nextPosition", .integer(1)), ("ownHead", .integer(0)),
            ("established", .integer(0)), ("ready", .integer(0)), ("readyThrough", .integer(0)),
            ("historyComplete", .integer(founder ? 1 : 0)), ("completionProvider", .blob(Data())),
            ("completionTarget", .blob(Data())), ("completionPosition", .integer(0)),
            ("historyProvider", .blob(Data())), ("controlRepair", .integer(0)),
        ]
        values += Counters.keys.map { ($0, $0 == "originCount" ? .integer(1) : .integer(0)) }
        for (key, value) in values {
            try database.run("INSERT INTO meta(key, value) VALUES (?, ?)", [.text(key), value])
        }
        try database.run(
            "INSERT INTO origins(origin, received, head, applied) VALUES (?, 0, ?, 0)",
            [.blob(origin), .blob(JournalEnvelope.zeroDigest)]
        )
    }

    static func requireRegularFile(_ url: URL) throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw HostJournalError.storeMissing
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw HostJournalError.storeUnreadable("not a regular file")
        }
    }

    static func checkFormat(_ database: JournalDatabase) throws {
        let version = try database.first("PRAGMA user_version", [], { try $0.int64(0) }) ?? 0
        guard version == formatVersion else { throw HostJournalError.formatUnsupported(version) }
    }

    /// Checks every row against its own bytes, the per-origin chains, the
    /// position sequence, the mappings and the stored counters.
    static func validate(_ database: JournalDatabase) throws -> HostJournalCoreView {
        guard try database.first("PRAGMA quick_check", [], { try $0.text(0) }) == "ok" else {
            throw HostJournalError.storeCorrupt("quick_check")
        }
        let meta = try readMeta(database)
        var counters = Counters()
        var heads: [Data: (received: UInt64, digest: Data)] = [:]
        var lastPositions: [Data: UInt64] = [:]
        var positions: UInt64 = 0
        var maxPosition: UInt64 = 0
        var ownPayloads: [UInt64: Data] = [:]
        try database.rows("SELECT origin, sequence, envelope, digest, position FROM records ORDER BY origin, sequence") { row in
            let envelope = try stored(try row.blob(2))
            let origin = try row.blob(0)
            let sequence = try row.unsigned(1)
            let previous = heads[origin] ?? (0, JournalEnvelope.zeroDigest)
            guard envelope.origin == origin, envelope.sequence == sequence, envelope.digest == (try row.blob(3)),
                  sequence == previous.received + 1, envelope.prior == previous.digest
            else { throw HostJournalError.storeCorrupt("record chain") }
            heads[origin] = (sequence, envelope.digest)
            if origin == meta.origin {
                guard row.isNull(4) else { throw HostJournalError.storeCorrupt("own position") }
                ownPayloads[sequence] = Data(SHA256.hash(data: envelope.payload))
            } else {
                let position = try row.unsigned(4)
                guard position >= 1, position > lastPositions[origin] ?? 0 else {
                    throw HostJournalError.storeCorrupt("position order")
                }
                lastPositions[origin] = position
                positions += 1
                maxPosition = max(maxPosition, position)
            }
            counters.recordCount += 1
            counters.recordBytes += UInt64(envelope.bytes.count)
        }
        guard positions == meta.nextPosition - 1, maxPosition == positions,
              (heads[meta.origin]?.received ?? 0) == meta.ownHead
        else { throw HostJournalError.storeCorrupt("positions") }
        var applied: [Data: UInt64] = [:]
        try database.rows(
            "SELECT origin, MAX(sequence) FROM records WHERE position IS NOT NULL AND position <= ? GROUP BY origin",
            [try JournalDatabase.integer(meta.appliedThrough)]
        ) { applied[try $0.blob(0)] = try $0.unsigned(1) }
        try database.rows("SELECT origin, received, head, applied FROM origins") { row in
            let origin = try row.blob(0)
            let head = heads[origin] ?? (0, JournalEnvelope.zeroDigest)
            guard origin.count == 16, try row.unsigned(1) == head.received, try row.blob(2) == head.digest,
                  try row.unsigned(3) == (origin == meta.origin ? 0 : applied[origin] ?? 0)
            else { throw HostJournalError.storeCorrupt("origin \(origin.count)") }
            counters.originCount += 1
        }
        let knownOrigins = try originSet(database)
        guard Set(heads.keys).isSubset(of: knownOrigins), knownOrigins.contains(meta.origin) else {
            throw HostJournalError.storeCorrupt("origins")
        }
        var mappings: UInt64 = 0
        try database.rows("SELECT id, sequence, payloadDigest FROM submissions") { row in
            guard try row.blob(0).count == 16, ownPayloads[try row.unsigned(1)] == (try row.blob(2)) else {
                throw HostJournalError.storeCorrupt("submission")
            }
            mappings += 1
        }
        guard mappings == meta.ownHead else { throw HostJournalError.storeCorrupt("submissions") }
        try database.rows("SELECT origin, sequence, envelope, digest FROM pending") { row in
            let envelope = try stored(try row.blob(2))
            let received = heads[envelope.origin]?.received ?? 0
            guard envelope.origin == (try row.blob(0)), envelope.sequence == (try row.unsigned(1)),
                  envelope.digest == (try row.blob(3)), envelope.sequence > received + 1, envelope.origin != meta.origin,
                  knownOrigins.contains(envelope.origin)
            else { throw HostJournalError.storeCorrupt("pending") }
            counters.pendingCount += 1
            counters.pendingBytes += UInt64(envelope.bytes.count)
        }
        for (table, column) in [("quarantine", "bytes"), ("heldInbox", "plaintext")] {
            try database.rows("SELECT sender, \(column), digest, cursor FROM \(table)") { row in
                let bytes = try row.blob(1)
                guard try row.blob(0).count == 32, Data(SHA256.hash(data: bytes)) == (try row.blob(2)),
                      try row.int64(3) >= 0
                else {
                    throw HostJournalError.storeCorrupt(table)
                }
                if table == "quarantine" {
                    counters.quarantineCount += 1
                    counters.quarantineBytes += UInt64(bytes.count)
                } else {
                    counters.heldCount += 1
                    counters.heldBytes += UInt64(bytes.count)
                }
            }
        }
        guard counters == meta.counters else { throw HostJournalError.storeCorrupt("counters") }
        if meta.historyComplete, let target = meta.completionTarget {
            guard target.allSatisfy({ (heads[$0.key]?.received ?? 0) >= $0.value }) else {
                throw HostJournalError.storeCorrupt("completion")
            }
        }
        guard meta.readyThrough <= meta.capturedThrough else { throw HostJournalError.storeCorrupt("ready") }
        return meta.view
    }

    private static func originSet(_ database: JournalDatabase) throws -> Set<Data> {
        var origins: Set<Data> = []
        try database.rows("SELECT origin FROM origins") { origins.insert(try $0.blob(0)) }
        return origins
    }

    private static func protect(_ url: URL) throws {
        try FileManager.default.setAttributes(ProtectedStorage.fileAttributes, ofItemAtPath: url.path)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var target = url
        try target.setResourceValues(excluded)
    }

    /// Parses an envelope read back from the file; damage is corruption.
    static func stored(_ bytes: Data) throws -> JournalEnvelope {
        do {
            return try JournalEnvelope(parsing: bytes)
        } catch {
            throw HostJournalError.storeCorrupt("envelope: \(error)")
        }
    }

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
