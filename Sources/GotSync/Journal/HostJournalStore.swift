import CryptoKit
import Foundation
import os
import SQLite3

enum JournalCapacity: Equatable, Sendable {
    case submitBudget
    /// One `submit` call's encoded envelopes, headers included and repeated
    /// mutation IDs counted, exceed `limit` bytes.
    case submitCallTooLarge(limit: Int)
    case history
    case pending
    case quarantine
    case origins
}

enum JournalStoreError: Error, Equatable {
    case storage(code: Int32, message: String)
    case valueOutOfRange
    case invalidArgument(String)
    case storeExists
    case storeMissing
    case storeUnreadable(String)
    case formatUnsupported(Int64)
    case storeCorrupt(String)
    case retired
    /// The engine stopped host work on this handle; only the handoff remains.
    case fenced
    /// A window proof no longer matches this journal's intake state.
    case proofStale
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
    case capacity(JournalCapacity)
    case fork(origin: Data, sequence: UInt64)
    case retainedRecordMissing(origin: Data, sequence: UInt64)
    case foreignOwnOrigin(sequence: UInt64)
    case quarantineConflict(sender: Data, cursor: UInt64)
    case heldInboxConflict(sender: Data, cursor: UInt64)
    case exportCursorMismatch
    case exportRevisionChanged
    case notArchived
    case confirmationMismatch
    /// Delivery is held while a snapshot bootstrap is unresolved.
    case bootstrapPending
    /// The store's ancestry needs the host's explicit preserving resolution.
    case ancestryUnresolved
    /// The mutation was captured at or before the finalization fence and its
    /// mapping was released; it is never accepted as a new mutation.
    case mutationFinalized
    /// A mutation lacks its capture counter after mappings were released.
    case captureRequired
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
    /// Encoded envelope bytes, headers included, one `submit` call may carry.
    var submitCallBytes = 262_144

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
    /// The capture counter saved with the outbox entry; required once
    /// mappings were released under the finalization fence.
    var capturedAt: UInt64? = nil
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
    let refusal: JournalCapacity?
}

/// A frozen window's fork, predecessor and own-origin proof, built in
/// bounded steps by `HostJournalStore.extendProof` and bound to one
/// writer generation's intake state.
struct HostWindowProof: Sendable {
    enum Phase: Equatable {
        case parse(Int)
        case check(arrival: Int, envelope: Int)
        /// Walks the touched origins' chains; `sequence` 0 starts an origin.
        case walk(origin: Int, sequence: UInt64, prior: Data)
        case complete
    }

    let id = UUID()
    let generation: UUID
    let journalID: Data
    fileprivate(set) var epoch: UInt64
    let arrivals: [HostJournalArrival]
    fileprivate(set) var parsed: [[JournalEnvelope]?] = []
    fileprivate var incoming: [JournalRecordID: JournalEnvelope] = [:]
    fileprivate var touched: Set<Data> = []
    fileprivate var walkOrder: [Data] = []
    fileprivate(set) var phase: Phase = .parse(0)
    /// Arrivals already taken by `intake(next:of:)`.
    fileprivate(set) var consumed = 0
    /// Arrivals carrying a removed below-floor record without a run proving
    /// it; they are quarantined, never taken as duplicates.
    fileprivate(set) var belowFloor: Set<Int> = []

    var isComplete: Bool { phase == .complete }

    fileprivate init(generation: UUID, journalID: Data, epoch: UInt64, arrivals: [HostJournalArrival]) {
        self.generation = generation
        self.journalID = journalID
        self.epoch = epoch
        self.arrivals = arrivals
    }
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
    /// A snapshot bootstrap this journal requested; nil keeps full history.
    let bootstrap: HostJournalBootstrapState?
    /// The committed all-member retention floor; nil keeps every record.
    let retention: HostJournalRetentionState?
    /// The store the host declared at enrollment; nil before, or for profiles without ancestry.
    let incarnation: HostStoreIncarnationRecord?
    let ancestryResolved: Bool
    let reclamation: HostJournalReclamationState?
    let finalization: HostJournalFinalizationState?

    /// Founded the group: complete from the start, with no provider.
    var isFounder: Bool { historyComplete && completionProvider == nil && completionTarget == nil }
    var ancestry: HostAncestryKind? {
        incarnation.map { HostAncestryKind.classify($0, group: group, founder: isFounder, frontier: reclamation?.frontier) }
    }
    var isAncestryResolved: Bool { ancestry.map { $0.resolvesItself || ancestryResolved } ?? true }

    var isRetired: Bool { retirement != nil }
    var isDeliveryHeld: Bool { bootstrap?.phase.holdsDelivery == true || retention?.floorApplied == false }
    /// The host applied every record of its completed history.
    var historyApplied: Bool { historyComplete && appliedThrough >= completionPosition && !isDeliveryHeld }
    var undelivered: UInt64 { delivered - appliedThrough }
    var retainedCount: UInt64 { recordCount + pendingCount }
    var retainedBytes: UInt64 { recordBytes + pendingBytes }
}

/// What one commit left: the core view, the complete origin inventory and
/// the proof epoch. Built inside the transaction before COMMIT; it holds no
/// record history, only per-origin heads.
struct HostJournalSnapshot: Equatable, Sendable {
    /// The connection generation that committed it.
    let generation: UUID
    /// Rises with every commit of this generation.
    let commitSequence: UInt64
    let view: HostJournalCoreView
    /// Every origin row in byte order: the own origin, received heads and
    /// origins with only pending records.
    let origins: [Data]
    /// Origins with a received head above zero, the own origin at its head.
    let received: [Data: UInt64]
    /// Some pending row continues its origin's received head.
    let hasPromotable: Bool
    let intakeEpoch: UInt64
}

/// A durable host record journal for one group generation on one SQLite
/// connection. Every mutation is one SQLite transaction; `view` changes only
/// after its commit succeeds. Not thread-safe: the engine reaches it only
/// through the `HostJournalWriter` that owns it.
final class HostJournalStore {
    static let filePrefix = "host-journal-"
    static let fileSuffix = ".sqlite3"
    static let creatingSuffix = ".creating"
    nonisolated static let formatVersion: Int64 = 3
    /// A journal some of whose records were removed below a retention floor.
    /// Earlier libraries refuse it as `formatUnsupported` instead of reading
    /// the missing rows as corruption.
    nonisolated static let compactedFormatVersion: Int64 = 4
    /// Full validations run on the main thread, for tests of cold opening.
    nonisolated static let mainThreadValidations = OSAllocatedUnfairLock(initialState: 0)

    let url: URL
    let limits: HostJournalLimits
    /// Identifies this connection; window proofs and snapshots carry it.
    let generation = UUID()
    private(set) var snapshot: HostJournalSnapshot
    var view: HostJournalCoreView { snapshot.view }
    /// Set by a successful `resume` in this process; submission, enumeration
    /// and application require it.
    private(set) var isResumed = false
    /// Set once the engine starts closing or replaces this generation; host
    /// enrollment, submission, application and readiness are refused from then
    /// on, while the handoff and export stay available.
    private(set) var isHostFenced = false
    /// Advanced by every commit that changes what a window proof read:
    /// intake, promotion and retirement. Host submission and application
    /// leave it alone; see `proofEffects`.
    var intakeEpoch: UInt64 { snapshot.intakeEpoch }
    /// Whether some pending row continues its origin's received head and
    /// waits for `promote`.
    var hasPromotable: Bool { snapshot.hasPromotable }
    var faultHookForTesting: ((HostJournalCommitPoint) throws -> Void)?
    /// The window proof the engine builds through its writer.
    private var activeProof: HostWindowProof?
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
            throw JournalStoreError.invalidArgument("group")
        }
        let journalID = randomBytes(16)
        let url = fileURL(in: directory, journalID: journalID)
        let staging = URL(fileURLWithPath: url.path + creatingSuffix)
        let manager = FileManager.default
        guard !manager.fileExists(atPath: url.path), !manager.fileExists(atPath: staging.path) else {
            throw JournalStoreError.storeExists
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
        } catch JournalStoreError.storage(let code, _) where code == JournalDatabase.hotJournalCode {
            inspected = nil
        } catch JournalStoreError.storage(let code, let message) {
            throw JournalStoreError.storeUnreadable("\(code): \(message)")
        }
        do {
            let database = try JournalDatabase(url: url, readOnly: false)
            let view = try inspected ?? inspect(database)
            try configure(database)
            return try HostJournalStore(url: url, limits: limits, database: database, view: view)
        } catch JournalStoreError.storage(let code, let message) {
            throw JournalStoreError.storeUnreadable("\(code): \(message)")
        }
    }

    /// Opens a journal that `HostJournalPreparation` validated, after
    /// checking under the write lock that the file and its contents are the
    /// ones prepared. Never validates again and never waits for the lock;
    /// the connection then waits as ordinary connections do. Returns nil when
    /// anything changed or is busy; the caller prepares again.
    static func install(_ prepared: PreparedHostJournal, limits: HostJournalLimits = .standard) throws -> HostJournalStore? {
        let url = prepared.url
        for suffix in ["-journal", "-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
            return nil
        }
        try requireRegularFile(url)
        let database: JournalDatabase
        do {
            database = try JournalDatabase(url: url, readOnly: false, busyTimeoutMilliseconds: 0)
            try database.execute("BEGIN IMMEDIATE")
        } catch JournalStoreError.storage(let code, _) where code & 0xFF == SQLITE_BUSY {
            return nil
        } catch JournalStoreError.storage(let code, let message) {
            throw JournalStoreError.storeUnreadable("\(code): \(message)")
        }
        do {
            try checkFormat(database)
            guard try database.first("PRAGMA journal_mode", [], { try $0.text(0) }) == "delete",
                  try readMeta(database).view == prepared.view,
                  try HostJournalPreparation.fileToken(url, database) == prepared.token
            else {
                try? database.execute("ROLLBACK")
                return nil
            }
            try database.execute("COMMIT")
            try configure(database)
            guard try !database.hasMoved() else { return nil }
        } catch {
            try? database.execute("ROLLBACK")
            return nil
        }
        database.setBusyTimeout(JournalDatabase.defaultBusyTimeoutMilliseconds)
        return try HostJournalStore(url: url, limits: limits, database: database, view: prepared.view)
    }

    private static func inspect(_ database: JournalDatabase) throws -> HostJournalCoreView {
        try database.execute("BEGIN")
        defer { try? database.execute("COMMIT") }
        try checkFormat(database)
        let mode = try database.first("PRAGMA journal_mode", [], { try $0.text(0) }) ?? ""
        guard mode == "delete" else {
            throw JournalStoreError.storeCorrupt("journal mode \(mode)")
        }
        return try validate(database)
    }

    private init(url: URL, limits: HostJournalLimits, database: JournalDatabase, view: HostJournalCoreView) throws {
        self.url = url
        self.limits = limits
        self.database = database
        snapshot = HostJournalSnapshot(
            generation: generation, commitSequence: 0, view: view, origins: [], received: [:], hasPromotable: false, intakeEpoch: 0
        )
        snapshot = try makeSnapshot(view: view, sequence: 0, epoch: 0)
    }

    // MARK: - Enrollment

    /// Starts an enrollment that the host confirms with `resume` after saving
    /// the returned provenance. Refused once an enrollment was confirmed,
    /// whether or not any record exists.
    func enroll(incarnation: HostStoreIncarnationRecord? = nil) throws -> HostJournalProvenance {
        try requireHostOpen()
        if let incarnation, !incarnation.isWellFormed { throw JournalStoreError.invalidArgument("incarnation") }
        return try transaction("enroll") {
            let meta = try readMeta()
            guard meta.retirement == nil else { throw JournalStoreError.retired }
            if case .confirmed = meta.enrollment { throw JournalStoreError.hostProvenanceMissing }
            if let incarnation {
                if let stored = meta.incarnation, stored != incarnation { throw JournalStoreError.hostProvenanceMismatch }
                if meta.incarnation == nil {
                    try setSnapshotMeta("incarnation", .blob(try ReplicaCanonicalJSON.encode(incarnation)))
                }
            }
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
        try requireHostOpen()
        _ = try JournalDatabase.integer(stored.capturedThrough)
        let result = try transaction("resume") { () -> HostJournalProvenance in
            let meta = try readMeta()
            guard stored.journalID == meta.journalID else { throw JournalStoreError.staleJournal }
            guard meta.retirement == nil else { throw JournalStoreError.retired }
            switch meta.enrollment {
            case .none:
                throw JournalStoreError.enrollmentRequired
            case .pending(let enrollmentID):
                guard stored.enrollmentID == enrollmentID, stored.appliedThrough == 0 else {
                    throw JournalStoreError.hostProvenanceMismatch
                }
                try setMeta("enrollment", .text("confirmed"))
                try setMeta("capturedThrough", try JournalDatabase.integer(stored.capturedThrough))
                try bumpRevision(meta)
                return HostJournalProvenance(
                    journalID: meta.journalID, enrollmentID: enrollmentID,
                    appliedThrough: 0, capturedThrough: stored.capturedThrough
                )
            case .confirmed(let enrollmentID):
                guard stored.enrollmentID == enrollmentID else { throw JournalStoreError.hostProvenanceMismatch }
                guard stored.capturedThrough >= meta.capturedThrough else { throw JournalStoreError.hostCaptureRegressed }
                guard stored.appliedThrough >= meta.appliedThrough else { throw JournalStoreError.hostApplicationRegressed }
                guard stored.appliedThrough < meta.nextPosition else {
                    throw JournalStoreError.positionOutOfRange(stored.appliedThrough)
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
        guard !batch.isEmpty, batch.count <= limits.batch else { throw JournalStoreError.invalidArgument("batch") }
        for mutation in batch {
            guard mutation.id.count == 16 else { throw JournalStoreError.invalidArgument("mutation id") }
            guard mutation.payload.count <= JournalEnvelope.maxPayloadLength else {
                throw JournalStoreError.payloadTooLarge(mutation.payload.count)
            }
        }
        let encoded = batch.reduce(0) { $0 + JournalEnvelope.headerLength + $1.payload.count }
        guard encoded <= limits.submitCallBytes else {
            throw JournalStoreError.capacity(.submitCallTooLarge(limit: limits.submitCallBytes))
        }
        try requireResumed()
        _ = try JournalDatabase.integer(capturedThrough)
        return try transaction("submit") {
            let meta = try readMeta()
            guard meta.retirement == nil else { throw JournalStoreError.retired }
            guard case .confirmed = meta.enrollment else { throw JournalStoreError.enrollmentRequired }
            if meta.incarnation != nil {
                guard meta.view.historyApplied, !meta.view.isDeliveryHeld, meta.retention?.floorApplied != false,
                      meta.view.isAncestryResolved
                else { throw JournalStoreError.ancestryUnresolved }
            }
            guard capturedThrough >= meta.capturedThrough else { throw JournalStoreError.hostCaptureRegressed }
            var counters = meta.counters
            var ownHead = meta.ownHead
            var records: [JournalRecordID] = []
            for mutation in batch {
                let payloadDigest = Data(SHA256.hash(data: mutation.payload))
                if let existing = try database.first(
                    "SELECT sequence, payloadDigest FROM submissions WHERE id = ?", [.blob(mutation.id)],
                    { (try $0.unsigned(0), try $0.blob(1)) }
                ) {
                    guard existing.1 == payloadDigest else { throw JournalStoreError.hostMutationConflict(mutation.id) }
                    records.append(JournalRecordID(origin: meta.origin, sequence: existing.0))
                    continue
                }
                if let fence = meta.finalization {
                    guard let capturedAt = mutation.capturedAt, capturedAt <= capturedThrough else {
                        throw JournalStoreError.captureRequired
                    }
                    guard capturedAt > fence.capture else { throw JournalStoreError.mutationFinalized }
                }
                let head = try originHead(meta.origin)
                guard head.received == ownHead else { throw JournalStoreError.storeCorrupt("own head") }
                let envelope = try JournalEnvelope(
                    origin: meta.origin, sequence: ownHead + 1, prior: head.digest, payload: mutation.payload
                )
                let length = UInt64(envelope.bytes.count)
                guard counters.retainedCount + 1 <= limits.submitRecords,
                      counters.retainedBytes + length <= limits.submitBytes
                else { throw JournalStoreError.capacity(.submitBudget) }
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
    /// first one that does not fit. Pending records the arrivals make
    /// contiguous stay pending until `promote` moves them.
    func intake(_ arrivals: [HostJournalArrival]) throws -> HostJournalIntake {
        for arrival in arrivals {
            guard arrival.sender.count == 32 else { throw JournalStoreError.invalidArgument("sender") }
            _ = try JournalDatabase.integer(arrival.cursor)
        }
        guard !arrivals.isEmpty else { return HostJournalIntake(ownedArrivals: 0, refusal: nil) }
        return try intakeChecked(arrivals, parsed: arrivals.map(Self.parse), proven: false)
    }

    /// Takes the next `count` arrivals of a complete window proof without
    /// proving them again, and moves the proof to the state this commit
    /// leaves. Any other change since the proof throws `proofStale`.
    func intake(next count: Int, of proof: inout HostWindowProof) throws -> HostJournalIntake {
        try requireProofCurrent(proof)
        guard proof.isComplete, count > 0, proof.consumed + count <= proof.arrivals.count else {
            throw JournalStoreError.invalidArgument("proof range")
        }
        let range = proof.consumed..<(proof.consumed + count)
        let quarantined = Set(proof.belowFloor.filter(range.contains).map { $0 - range.lowerBound })
        let result = try intakeChecked(
            Array(proof.arrivals[range]), parsed: Array(proof.parsed[range]), proven: true, quarantined: quarantined
        )
        proof.epoch = intakeEpoch
        proof.consumed += result.ownedArrivals
        return result
    }

    private func intakeChecked(
        _ arrivals: [HostJournalArrival], parsed: [[JournalEnvelope]?], proven: Bool, quarantined: Set<Int> = []
    ) throws -> HostJournalIntake {
        do {
            return try intakeTransaction(arrivals, parsed: parsed, proven: proven, quarantined: quarantined)
        } catch let refused as NothingOwned {
            return HostJournalIntake(ownedArrivals: 0, refusal: refused.refusal)
        }
    }

    /// Rolls back an intake that owns no arrival, so a refusal leaves the file untouched.
    private struct NothingOwned: Error {
        let refusal: JournalCapacity?
    }

    private func intakeTransaction(
        _ arrivals: [HostJournalArrival], parsed: [[JournalEnvelope]?], proven: Bool, quarantined proved: Set<Int>
    ) throws -> HostJournalIntake {
        try transaction("intake") {
            let meta = try readMeta()
            guard meta.retirement == nil else { throw JournalStoreError.retired }
            let quarantined = proven ? proved : try preflight(parsed, meta: meta)
            var counters = meta.counters
            var nextPosition = meta.nextPosition
            var owned = 0
            var refusal: JournalCapacity?
            for (index, (arrival, envelopes)) in zip(arrivals, parsed).enumerated() {
                try database.execute("SAVEPOINT arrival")
                let before = (counters, nextPosition)
                if quarantined.contains(index) {
                    try quarantine(arrival, reason: "belowFloor", counters: &counters)
                } else if let envelopes {
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

    /// Checks every envelope and returns the arrivals to quarantine because
    /// they carry a removed below-floor record no run proves.
    private func preflight(_ parsed: [[JournalEnvelope]?], meta: Meta) throws -> Set<Int> {
        var belowFloor: Set<Int> = []
        for (index, envelopes) in parsed.enumerated() {
            guard let envelopes, let retention = meta.retention else { continue }
            if try envelopes.contains(where: { try isPrunedBelowFloor($0, retention) }),
               try !dischargesBelowFloor(envelopes, retention) {
                belowFloor.insert(index)
            }
        }
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
        for (index, envelopes) in parsed.enumerated() where !belowFloor.contains(index) {
          for envelope in envelopes ?? [] {
            if let earlier = incoming[envelope.id] {
                guard earlier.digest == envelope.digest else {
                    throw JournalStoreError.fork(origin: envelope.origin, sequence: envelope.sequence)
                }
                continue
            }
            incoming[envelope.id] = envelope
            let received = try originHead(envelope.origin).received
            if envelope.origin == meta.origin, envelope.sequence > meta.ownHead {
                throw JournalStoreError.foreignOwnOrigin(sequence: envelope.sequence)
            }
            if envelope.sequence <= received {
                if let retention = meta.retention, try isPrunedBelowFloor(envelope, retention) {
                    continue
                }
                guard let retained = try retainedDigest(envelope.id) else {
                    throw JournalStoreError.retainedRecordMissing(origin: envelope.origin, sequence: envelope.sequence)
                }
                guard retained == envelope.digest else {
                    throw JournalStoreError.fork(origin: envelope.origin, sequence: envelope.sequence)
                }
            } else {
                if let pending = try pendingEnvelope(envelope.id), pending.digest != envelope.digest {
                    throw JournalStoreError.fork(origin: envelope.origin, sequence: envelope.sequence)
                }
                origins.insert(envelope.origin)
            }
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
                    throw JournalStoreError.fork(origin: origin, sequence: sequence)
                }
                head = (sequence, candidate.digest)
                sequence += 1
            }
        }
        return belowFloor
    }

    /// A record at or below the floor whose row was removed. Every member
    /// received its floor's records before committing, and a joiner adopts
    /// the floor without them, so an absent row there is a removed one.
    private func isPrunedBelowFloor(_ envelope: JournalEnvelope, _ retention: HostJournalRetentionState) throws -> Bool {
        guard let anchor = retention.anchor(envelope.origin), envelope.sequence <= anchor.sequence else { return false }
        return try retainedDigest(envelope.id) == nil
    }

    /// Every removed below-floor record of the arrival lies in a contiguous
    /// run, linked by `prior`, that ends at the floor anchor's digest or right
    /// before a retained record whose `prior` is the run's last digest. The
    /// hash chain then makes the run exactly the removed bytes.
    private func dischargesBelowFloor(_ envelopes: [JournalEnvelope], _ retention: HostJournalRetentionState) throws -> Bool {
        for anchor in retention.anchors {
            let below = envelopes.filter { $0.origin == anchor.origin && $0.sequence <= anchor.sequence }
            guard !below.isEmpty else { continue }
            var runs: [[JournalEnvelope]] = []
            for envelope in below {
                if let last = runs.last?.last, envelope.sequence == last.sequence + 1 {
                    runs[runs.count - 1].append(envelope)
                } else {
                    runs.append([envelope])
                }
            }
            for run in runs where try run.contains(where: { try isPrunedBelowFloor($0, retention) }) {
                for (earlier, later) in zip(run, run.dropFirst()) where later.prior != earlier.digest {
                    return false
                }
                let last = run[run.count - 1]
                if last.sequence == anchor.sequence {
                    guard last.digest == anchor.digest else { return false }
                } else {
                    let next = JournalRecordID(origin: anchor.origin, sequence: last.sequence + 1)
                    guard let bytes = try database.first(
                        "SELECT envelope FROM records WHERE origin = ? AND sequence = ?",
                        [.blob(next.origin), try JournalDatabase.integer(next.sequence)], { try $0.blob(0) }
                    ), try Self.stored(bytes).prior == last.digest else { return false }
                }
            }
        }
        return true
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
        let head = try originHead(envelope.origin)
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
        guard envelope.prior == head.digest else {
            throw JournalStoreError.fork(origin: envelope.origin, sequence: envelope.sequence)
        }
        try insertRecord(envelope, position: nextPosition)
        nextPosition += 1
        counters.recordCount += 1
        counters.recordBytes += UInt64(envelope.bytes.count)
    }

    private func quarantine(_ arrival: HostJournalArrival, reason: String? = nil, counters: inout Counters) throws {
        let digest = Data(SHA256.hash(data: arrival.plaintext))
        let key: [JournalValue] = [.blob(arrival.sender), try JournalDatabase.integer(arrival.cursor)]
        if let existing = try database.first(
            "SELECT digest FROM quarantine WHERE sender = ? AND cursor = ?", key, { try $0.blob(0) }
        ) {
            guard existing == digest else {
                throw JournalStoreError.quarantineConflict(sender: arrival.sender, cursor: arrival.cursor)
            }
            return
        }
        try database.run(
            "INSERT INTO quarantine(sender, cursor, reason, bytes, digest) VALUES (?, ?, ?, ?, ?)",
            key + [.text(reason ?? (arrival.envelopes == nil ? "undecodable" : "malformedEnvelopes")), .blob(arrival.plaintext), .blob(digest)]
        )
        counters.quarantineCount += 1
        counters.quarantineBytes += UInt64(arrival.plaintext.count)
    }

    private func exceededLimit(_ counters: Counters) throws -> JournalCapacity? {
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

    /// Remote records after `position`, in position order. Nothing while a
    /// snapshot bootstrap holds delivery; records an installed snapshot
    /// covers are skipped.
    func incoming(after position: UInt64, limit: Int) throws -> [HostJournalIncoming] {
        try requireResumed()
        guard limit > 0, limit <= limits.batch else { throw JournalStoreError.invalidArgument("limit") }
        let bootstrap = view.bootstrap
        guard !view.isDeliveryHeld else { return [] }
        let (uncovered, coveredValues) = try Self.uncoveredClause(bootstrap?.coverage)
        var result: [HostJournalIncoming] = []
        try database.rows(
            "SELECT position, envelope FROM records WHERE position > ?\(uncovered) ORDER BY position LIMIT ?",
            [try JournalDatabase.integer(position)] + coveredValues + [.integer(Int64(limit))]
        ) { row in
            let envelope = try Self.stored(try row.blob(1))
            result.append(HostJournalIncoming(position: try row.unsigned(0), record: envelope.id, payload: envelope.payload))
        }
        return result
    }

    /// An SQL condition excluding records `coverage` covers, with its values.
    nonisolated private static func uncoveredClause(_ coverage: [Data: UInt64]?) throws -> (String, [JournalValue]) {
        guard let coverage, !coverage.isEmpty else { return ("", []) }
        var values: [JournalValue] = []
        var terms: [String] = []
        for (origin, sequence) in coverage.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
            terms.append("(origin = ? AND sequence <= ?)")
            values += [.blob(origin), try JournalDatabase.integer(sequence)]
        }
        return (" AND NOT (" + terms.joined(separator: " OR ") + ")", values)
    }

    func coveredThrough(after position: UInt64) throws -> UInt64? {
        try requireResumed()
        let meta = try readMeta()
        guard !meta.view.isDeliveryHeld else { throw JournalStoreError.bootstrapPending }
        guard position < meta.nextPosition else { throw JournalStoreError.positionOutOfRange(position) }
        let covered = try Self.pastCovered(position, coverage: meta.bootstrap?.coverage, in: database, next: meta.nextPosition)
        return covered > position ? covered : nil
    }

    /// Records that the host committed its business state through `position`.
    func markApplied(through position: UInt64) throws {
        try requireResumed()
        _ = try JournalDatabase.integer(position)
        try transaction("markApplied") {
            let meta = try readMeta()
            guard meta.retirement == nil else { throw JournalStoreError.retired }
            guard position < meta.nextPosition else { throw JournalStoreError.positionOutOfRange(position) }
            guard position > meta.appliedThrough else { return }
            guard !meta.view.isDeliveryHeld else { throw JournalStoreError.bootstrapPending }
            try applyThrough(position, from: meta.appliedThrough)
            try bumpRevision(meta)
        }
    }

    /// The end of the following contiguous covered run.
    nonisolated private static func pastCovered(
        _ position: UInt64, coverage: [Data: UInt64]?, in database: JournalDatabase, next nextPosition: UInt64
    ) throws -> UInt64 {
        guard let coverage, !coverage.isEmpty else { return position }
        let (uncovered, values) = try uncoveredClause(coverage)
        let firstUncovered = try database.first(
            "SELECT MIN(position) FROM records WHERE position > ?\(uncovered)",
            [try JournalDatabase.integer(position)] + values, { $0.isNull(0) ? nil : try $0.unsigned(0) }
        ) ?? nil
        return (firstUncovered ?? nextPosition) - 1
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
        var proof = try beginProof(arrivals)
        while try !extendProof(&proof, maxUnits: .max, maxBytes: .max) {}
    }

    // MARK: - Window proof

    func beginProof(_ arrivals: [HostJournalArrival]) throws -> HostWindowProof {
        for arrival in arrivals {
            guard arrival.sender.count == 32 else { throw JournalStoreError.invalidArgument("sender") }
            _ = try JournalDatabase.integer(arrival.cursor)
        }
        return HostWindowProof(generation: generation, journalID: view.journalID, epoch: intakeEpoch, arrivals: arrivals)
    }

    /// Replaces the active proof with a new one for `arrivals`; a late call
    /// for an earlier proof then fails with `proofStale`.
    func beginActiveProof(_ arrivals: [HostJournalArrival]) throws -> UUID {
        activeProof = nil
        let proof = try beginProof(arrivals)
        activeProof = proof
        return proof.id
    }

    func extendActiveProof(_ id: UUID, maxUnits: Int = 512, maxBytes: Int = 262_144) throws -> Bool {
        guard var proof = activeProof, proof.id == id else { throw JournalStoreError.proofStale }
        activeProof = nil
        defer { activeProof = proof }
        return try extendProof(&proof, maxUnits: maxUnits, maxBytes: maxBytes)
    }

    /// Takes the active proof's arrivals `start..<start + count`; any other
    /// proof or position is stale.
    func intake(next count: Int, ofActive id: UUID, from start: Int) throws -> HostJournalIntake {
        guard var proof = activeProof, proof.id == id, proof.consumed == start else { throw JournalStoreError.proofStale }
        activeProof = nil
        defer { activeProof = proof }
        return try intake(next: count, of: &proof)
    }

    /// Advances `proof` by at most `maxBytes` of envelope parsing, or by at
    /// most `maxUnits` envelope checks or predecessor steps inside one short
    /// read transaction. Returns whether the whole window is proven.
    func extendProof(_ proof: inout HostWindowProof, maxUnits: Int = 512, maxBytes: Int = 262_144) throws -> Bool {
        try requireProofCurrent(proof)
        switch proof.phase {
        case .complete:
            return true
        case .parse(var index):
            var bytes = 0
            while index < proof.arrivals.count {
                let size = proof.arrivals[index].envelopes?.reduce(0) { $0 + $1.count } ?? 0
                if bytes > 0, bytes + size > maxBytes { break }
                proof.parsed.append(Self.parse(proof.arrivals[index]))
                bytes += size
                index += 1
            }
            proof.phase = index < proof.arrivals.count ? .parse(index) : .check(arrival: 0, envelope: 0)
        case .check(var arrival, var position):
            try database.execute("BEGIN")
            defer { try? database.execute("COMMIT") }
            let meta = try readMeta()
            var heads: [Data: UInt64] = [:]
            var units = 0
            while arrival < proof.parsed.count, units < maxUnits {
                guard let envelopes = proof.parsed[arrival], position < envelopes.count else {
                    arrival += 1
                    position = 0
                    continue
                }
                let envelope = envelopes[position]
                position += 1
                units += 1
                if proof.belowFloor.contains(arrival) {
                    continue
                }
                if let retention = meta.retention, try isPrunedBelowFloor(envelope, retention) {
                    if try !dischargesBelowFloor(envelopes, retention) {
                        proof.belowFloor.insert(arrival)
                    }
                    continue
                }
                if let earlier = proof.incoming[envelope.id] {
                    guard earlier.digest == envelope.digest else {
                        throw JournalStoreError.fork(origin: envelope.origin, sequence: envelope.sequence)
                    }
                    continue
                }
                proof.incoming[envelope.id] = envelope
                if envelope.origin == meta.origin, envelope.sequence > meta.ownHead {
                    throw JournalStoreError.foreignOwnOrigin(sequence: envelope.sequence)
                }
                let received = try heads[envelope.origin] ?? originHead(envelope.origin).received
                heads[envelope.origin] = received
                if envelope.sequence <= received {
                    guard let retained = try retainedDigest(envelope.id) else {
                        throw JournalStoreError.retainedRecordMissing(origin: envelope.origin, sequence: envelope.sequence)
                    }
                    guard retained == envelope.digest else {
                        throw JournalStoreError.fork(origin: envelope.origin, sequence: envelope.sequence)
                    }
                } else {
                    if meta.counters.pendingCount > 0, let pending = try pendingEnvelope(envelope.id),
                       pending.digest != envelope.digest {
                        throw JournalStoreError.fork(origin: envelope.origin, sequence: envelope.sequence)
                    }
                    proof.touched.insert(envelope.origin)
                }
            }
            if arrival < proof.parsed.count {
                proof.phase = .check(arrival: arrival, envelope: position)
            } else {
                proof.walkOrder = proof.touched.sorted { $0.lexicographicallyPrecedes($1) }
                proof.phase = proof.walkOrder.isEmpty ? .complete : .walk(origin: 0, sequence: 0, prior: Data())
            }
        case .walk(var origin, var sequence, var prior):
            try database.execute("BEGIN")
            defer { try? database.execute("COMMIT") }
            let hasPending = try readMeta().counters.pendingCount > 0
            var units = 0
            while origin < proof.walkOrder.count, units < maxUnits {
                let id = proof.walkOrder[origin]
                if sequence == 0 {
                    let head = try originHead(id)
                    sequence = head.received + 1
                    prior = head.digest
                }
                units += 1
                let next = JournalRecordID(origin: id, sequence: sequence)
                guard let candidate = try proof.incoming[next] ?? (hasPending ? pendingEnvelope(next) : nil) else {
                    origin += 1
                    sequence = 0
                    continue
                }
                guard candidate.prior == prior else {
                    throw JournalStoreError.fork(origin: id, sequence: sequence)
                }
                prior = candidate.digest
                sequence += 1
            }
            proof.phase = origin < proof.walkOrder.count ? .walk(origin: origin, sequence: sequence, prior: prior) : .complete
        }
        return proof.isComplete
    }

    var isInTransactionForTesting: Bool { database.isInTransaction }

    private func requireProofCurrent(_ proof: HostWindowProof) throws {
        guard proof.generation == generation, proof.journalID == view.journalID, proof.epoch == intakeEpoch,
              view.retirement == nil
        else {
            throw JournalStoreError.proofStale
        }
    }

    // MARK: - Promotion

    /// Moves at most `maxRecords` records, or `maxBytes` of envelopes, from
    /// the pending rows that continue a received head into `records`, in
    /// sequence order, across all origins together. Returns how many moved.
    @discardableResult
    func promote(maxRecords: Int = 128, maxBytes: Int = 131_072) throws -> Int {
        guard hasPromotable else { return 0 }
        let moved = try transaction("promote") { () -> Int in
            let meta = try readMeta()
            guard meta.retirement == nil else { throw JournalStoreError.retired }
            var origins: [Data] = []
            try database.rows(
                "SELECT origins.origin FROM origins JOIN pending ON pending.origin = origins.origin AND pending.sequence = origins.received + 1 ORDER BY origins.origin"
            ) { origins.append(try $0.blob(0)) }
            var counters = meta.counters
            var nextPosition = meta.nextPosition
            var moved = 0
            var bytes = 0
            promoting: for origin in origins {
                var head = try originHead(origin)
                while moved < maxRecords, let record = try pendingEnvelope(JournalRecordID(origin: origin, sequence: head.received + 1)) {
                    guard moved == 0 || bytes + record.bytes.count <= maxBytes else { break promoting }
                    guard record.prior == head.digest else { throw JournalStoreError.storeCorrupt("pending chain") }
                    try database.run(
                        "DELETE FROM pending WHERE origin = ? AND sequence = ?",
                        [.blob(record.origin), try JournalDatabase.integer(record.sequence)]
                    )
                    try insertRecord(record, position: nextPosition)
                    nextPosition += 1
                    counters.pendingCount -= 1
                    counters.pendingBytes -= UInt64(record.bytes.count)
                    counters.recordCount += 1
                    counters.recordBytes += UInt64(record.bytes.count)
                    head = (record.sequence, record.digest)
                    moved += 1
                    bytes += record.bytes.count
                }
                if moved >= maxRecords { break }
            }
            guard moved > 0 else { return 0 }
            try setMeta("nextPosition", try JournalDatabase.integer(nextPosition))
            try writeCounters(counters)
            if !meta.historyComplete, let target = meta.completionTarget {
                try evaluateCompletion(target)
            }
            try bumpRevision(meta)
            return moved
        }
        return moved
    }

    // MARK: - Engine state

    /// Records that a main checkpoint references this generation.
    func markEstablished() throws {
        try transaction("markEstablished") {
            let meta = try readMeta()
            guard meta.retirement == nil else { throw JournalStoreError.retired }
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
            guard meta.retirement == nil else { throw JournalStoreError.retired }
            guard case .confirmed = meta.enrollment else { throw JournalStoreError.enrollmentRequired }
            guard meta.retention?.floorApplied != false else { throw JournalStoreError.bootstrapPending }
            guard meta.view.isAncestryResolved else { throw JournalStoreError.ancestryUnresolved }
            guard meta.capturedThrough >= capturedThrough else { throw JournalStoreError.hostCaptureRegressed }
            guard !meta.isReady || capturedThrough > meta.readyThrough else { return }
            try setMeta("ready", .integer(1))
            try setMeta("readyThrough", try JournalDatabase.integer(max(capturedThrough, meta.readyThrough)))
            try bumpRevision(meta)
        }
    }

    /// Stores a provider's completion target. A target lower than the stored
    /// one in any origin, or any target after completion, is ignored. A
    /// requested bootstrap takes the snapshot offer, or the refusal, that
    /// came with the accepted target.
    @discardableResult
    func recordCompletionTarget(
        provider: Data, through target: [Data: UInt64], offer: HostSnapshotOffer? = nil, refusal: HostSnapshotRefusalReason? = nil
    ) throws -> Bool {
        guard provider.count == 32 else { throw JournalStoreError.invalidArgument("provider") }
        let encoded = try Self.encodeVector(target)
        return try transaction("recordCompletionTarget") {
            let meta = try readMeta()
            guard meta.retirement == nil else { throw JournalStoreError.retired }
            guard !meta.historyComplete else { return false }
            if let stored = meta.completionTarget {
                guard stored.allSatisfy({ target[$0.key] ?? 0 >= $0.value }) else { return false }
            }
            try setMeta("completionProvider", .blob(provider))
            try setMeta("completionTarget", .blob(encoded))
            if meta.bootstrap?.phase == .requested {
                if let offer, offer.isWellFormed, offer.anchors.allSatisfy({ target[$0.origin] ?? 0 >= $0.sequence }) {
                    try setSnapshotMeta("snapshotOffer", .blob(try ReplicaCanonicalJSON.encode(offer)))
                    try setSnapshotMeta("snapshotPhase", .text(HostSnapshotPhase.offered.rawValue))
                } else {
                    let reason: HostSnapshotRefusalReason = offer != nil ? .malformedOffer
                        : refusal.flatMap { HostSnapshotRefusalReason.providerReasons.contains($0) ? $0 : nil } ?? .notOffered
                    try setSnapshotRefusal(reason)
                }
            }
            try evaluateCompletion(target)
            try bumpRevision(meta)
            return true
        }
    }

    // MARK: - Snapshot bootstrap

    /// Requests a snapshot for a fresh journal: nothing applied, history
    /// incomplete and no earlier request. Delivery is held from now on.
    @discardableResult
    func requestSnapshot(schema: String) throws -> Bool {
        guard HostSnapshotSchemaName.isValid(schema) else { throw JournalStoreError.invalidArgument("schema") }
        return try transaction("requestSnapshot") {
            let meta = try readMeta()
            guard meta.retirement == nil, meta.bootstrap == nil, meta.appliedThrough == 0, !meta.historyComplete else { return false }
            try setSnapshotMeta("snapshotSchema", .text(schema))
            try setSnapshotMeta("snapshotPhase", .text(HostSnapshotPhase.requested.rawValue))
            try bumpRevision(meta)
            return true
        }
    }

    /// Refuses the bootstrap while it is in one of `phases`, keeping any
    /// offer; delivery returns to full history.
    @discardableResult
    func refuseSnapshot(_ reason: HostSnapshotRefusalReason, in phases: Set<HostSnapshotPhase>, id: Data? = nil) throws -> Bool {
        try transaction("refuseSnapshot") {
            let meta = try readMeta()
            guard meta.retirement == nil, let bootstrap = meta.bootstrap, phases.contains(bootstrap.phase),
                  id.map({ $0 == bootstrap.offer?.id }) ?? true
            else { return false }
            try setSnapshotRefusal(reason)
            try bumpRevision(meta)
            return true
        }
    }

    /// Moves the bootstrap of snapshot `id` from `from` to `to`, a phase
    /// that keeps delivery held; false when another step got there first.
    @discardableResult
    func advanceSnapshot(id: Data, from: HostSnapshotPhase, to: HostSnapshotPhase) throws -> Bool {
        guard to.holdsDelivery || to == .completed else { throw JournalStoreError.invalidArgument("phase") }
        return try transaction("advanceSnapshot") {
            let meta = try readMeta()
            guard meta.retirement == nil, let bootstrap = meta.bootstrap, bootstrap.phase == from, bootstrap.offer?.id == id else {
                return false
            }
            try setSnapshotMeta("snapshotPhase", .text(to.rawValue))
            try bumpRevision(meta)
            return true
        }
    }

    /// Every anchor names a record this journal received and retains with
    /// exactly that digest. Its chain to sequence one was checked on intake,
    /// so the covered records are the ones the snapshot was exported from.
    func verifySnapshotAnchors() throws -> Bool {
        let meta = try readMeta()
        guard meta.historyComplete, let offer = meta.bootstrap?.offer else { return false }
        for anchor in offer.anchors {
            let digest = try database.first(
                "SELECT digest FROM records WHERE origin = ? AND sequence = ?",
                [.blob(anchor.origin), try JournalDatabase.integer(anchor.sequence)], { try $0.blob(0) }
            )
            guard digest == anchor.digest else { return false }
        }
        return true
    }

    /// The cut a provider export must reflect: remote records applied
    /// through `appliedThrough` or covered by an installed snapshot, and
    /// every own record, each origin with its retained head digest.
    func snapshotExportCut() throws -> HostSnapshotExportCut {
        let meta = try readMeta()
        var vector: [Data: UInt64] = [:]
        try database.rows("SELECT origin, applied FROM origins WHERE applied > 0") { vector[try $0.blob(0)] = try $0.unsigned(1) }
        for (origin, sequence) in meta.bootstrap?.coverage ?? [:] {
            vector[origin] = max(vector[origin] ?? 0, sequence)
        }
        vector[meta.origin] = meta.ownHead
        var anchors: [HostSnapshotAnchor] = []
        for (origin, sequence) in vector.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) where sequence > 0 {
            guard let digest = try retainedDigest(JournalRecordID(origin: origin, sequence: sequence)) else {
                throw JournalStoreError.retainedRecordMissing(origin: origin, sequence: sequence)
            }
            anchors.append(HostSnapshotAnchor(origin: origin, sequence: sequence, digest: digest))
        }
        return HostSnapshotExportCut(
            journalID: meta.journalID, appliedThrough: meta.appliedThrough, capturedThrough: meta.capturedThrough, anchors: anchors
        )
    }

    func snapshotInstallPosition(id: Data) throws -> UInt64? {
        let meta = try readMeta()
        guard meta.retirement == nil, let bootstrap = meta.bootstrap, bootstrap.phase == .installing,
              let offer = bootstrap.offer, offer.id == id else { return nil }
        return try Self.pastCovered(meta.appliedThrough, coverage: offer.coverage, in: database, next: meta.nextPosition)
    }

    /// Records that the host installed snapshot `id`: its coverage is
    /// stored and the application mark moves over covered records.
    @discardableResult
    func commitSnapshotInstall(id: Data, appliedThrough: UInt64) throws -> Bool {
        try transaction("commitSnapshotInstall") {
            let meta = try readMeta()
            guard meta.retirement == nil, let bootstrap = meta.bootstrap, bootstrap.phase == .installing,
                  let offer = bootstrap.offer, offer.id == id
            else { return false }
            let coverage = offer.coverage
            let advanced = try Self.pastCovered(meta.appliedThrough, coverage: coverage, in: database, next: meta.nextPosition)
            guard advanced == appliedThrough else { throw JournalStoreError.invalidArgument("snapshot application mark") }
            try setSnapshotMeta("snapshotCoverage", .blob(try Self.encodeVector(coverage)))
            try setSnapshotMeta("snapshotPhase", .text(HostSnapshotPhase.installed.rawValue))
            if advanced > meta.appliedThrough {
                try applyThrough(advanced, from: meta.appliedThrough)
            }
            if let floor = offer.floor, let retention = meta.retention, retention.proposal == floor, !retention.floorApplied {
                try markFloorApplied(retention)
            }
            try bumpRevision(meta)
            return true
        }
    }

    // MARK: - Retention floor

    /// Why this journal cannot accept a floor at `anchors` now, or nil. Read
    /// before voting; `commitRetentionFloor` checks the record conditions again.
    func retentionDecline(_ anchors: [HostSnapshotAnchor]) throws -> HostRetentionDeclineReason? {
        let meta = try readMeta()
        let view = meta.view
        guard view.historyApplied, view.isReady, view.pendingCount == 0, view.quarantineCount == 0, view.heldCount == 0,
              !view.controlRepair, !view.isDeliveryHeld, meta.retirement == nil
        else { return .unsettled }
        return try floorDecline(anchors, meta: meta)
    }

    private func floorDecline(_ anchors: [HostSnapshotAnchor], meta: Meta) throws -> HostRetentionDeclineReason? {
        if let committed = meta.retention {
            guard committed.floorApplied else { return .unsettled }
            for old in committed.anchors {
                guard let new = anchors.first(where: { $0.origin == old.origin }), new.sequence >= old.sequence else {
                    return .belowCommittedFloor
                }
            }
        }
        for anchor in anchors {
            if let committed = meta.retention?.anchor(anchor.origin), committed.sequence == anchor.sequence {
                guard committed.digest == anchor.digest else { return .anchorMismatch }
                continue
            }
            guard let digest = try retainedDigest(JournalRecordID(origin: anchor.origin, sequence: anchor.sequence)) else {
                return .notCaughtUp
            }
            guard digest == anchor.digest else { return .anchorMismatch }
            if anchor.origin == meta.origin {
                guard anchor.sequence <= meta.ownHead else { return .notCaughtUp }
            } else {
                let applied = try database.first(
                    "SELECT applied FROM origins WHERE origin = ?", [.blob(anchor.origin)], { try $0.unsigned(0) }
                ) ?? 0
                guard anchor.sequence <= applied else { return .notCaughtUp }
            }
        }
        return nil
    }

    /// Commits a floor every current member accepted: records at or below it
    /// become removable. The checkpoint must reflect exactly the anchors.
    @discardableResult
    func commitRetentionFloor(round: Data, proposal: Data, checkpoint: HostSnapshotOffer, reclaimStores: [Data]? = nil) throws -> Bool {
        guard round.count == 16, proposal.count == 32, checkpoint.isWellFormed, checkpoint.floor == nil else {
            throw JournalStoreError.invalidArgument("floor")
        }
        if let reclaimStores, !HostJournalReclamationState(frontier: checkpoint.coverage, stores: reclaimStores, applied: false)
            .isWellFormed(at: checkpoint.anchors) {
            throw JournalStoreError.invalidArgument("reclamation")
        }
        return try transaction("commitRetentionFloor") {
            let meta = try readMeta()
            guard meta.retirement == nil else { throw JournalStoreError.retired }
            guard meta.retention?.proposal != proposal else { return false }
            guard try floorDecline(checkpoint.anchors, meta: meta) == nil else { return false }
            if reclaimStores != nil, !meta.view.isAncestryResolved { return false }
            try storeFloor(round: round, proposal: proposal, checkpoint: checkpoint, applied: true, meta: meta)
            if let reclaimStores {
                try storeReclamation(checkpoint.coverage, stores: reclaimStores, applied: false)
            }
            try bumpRevision(meta)
            return true
        }
    }

    /// Removes at most `maxRecords` records at or below the committed floor,
    /// lowest sequences first, and marks the file compacted. Returns how many.
    @discardableResult
    func pruneBelowFloor(maxRecords: Int = HostRetentionBounds.pruneStep) throws -> Int {
        guard let retention = view.retention, retention.floorApplied, view.retirement == nil else { return 0 }
        let (uncovered, values) = try Self.uncoveredClause(retention.floor)
        let covered = uncovered.replacingOccurrences(of: " AND NOT (", with: " AND (")
        return try transaction("pruneBelowFloor") {
            let meta = try readMeta()
            guard let current = meta.retention, current.proposal == retention.proposal else { return 0 }
            var removed: [(origin: Data, sequence: UInt64, bytes: UInt64, positioned: Bool)] = []
            try database.rows(
                "SELECT origin, sequence, length(envelope), position IS NOT NULL FROM records WHERE 1 = 1\(covered) ORDER BY sequence LIMIT ?",
                values + [.integer(Int64(maxRecords))]
            ) { row in
                removed.append((try row.blob(0), try row.unsigned(1), try row.unsigned(2), try row.int64(3) == 1))
            }
            guard !removed.isEmpty else { return 0 }
            for record in removed {
                try database.run(
                    "DELETE FROM records WHERE origin = ? AND sequence = ?",
                    [.blob(record.origin), try JournalDatabase.integer(record.sequence)]
                )
            }
            var counters = meta.counters
            let bytes = removed.reduce(UInt64(0)) { $0 + $1.bytes }
            counters.recordCount -= UInt64(removed.count)
            counters.recordBytes -= bytes
            try writeCounters(counters)
            try setSnapshotMeta("prunedRecords", try JournalDatabase.integer(current.prunedRecords + UInt64(removed.count)))
            try setSnapshotMeta("prunedBytes", try JournalDatabase.integer(current.prunedBytes + bytes))
            let positioned = UInt64(removed.filter(\.positioned).count)
            try setSnapshotMeta("prunedPositions", try JournalDatabase.integer(current.prunedPositions + positioned))
            try database.execute("PRAGMA user_version = \(Self.compactedFormatVersion)")
            try bumpRevision(meta)
            return removed.count
        }
    }

    /// Adopts a committed floor every other current member corroborated, for
    /// a joiner that never received the removed records: each origin's head
    /// starts at its anchor, so the tail above it promotes normally.
    @discardableResult
    func adoptRetentionFloor(
        round: Data, proposal: Data, checkpoint: HostSnapshotOffer, reclamation: HostJournalReclamationState? = nil
    ) throws -> Bool {
        guard round.count == 16, proposal.count == 32, checkpoint.isWellFormed, checkpoint.floor == nil else {
            throw JournalStoreError.invalidArgument("floor")
        }
        if let reclamation, !reclamation.isWellFormed(at: checkpoint.anchors) {
            throw JournalStoreError.invalidArgument("reclamation")
        }
        return try transaction("adoptRetentionFloor") {
            let meta = try readMeta()
            guard meta.retirement == nil, meta.retention == nil, meta.bootstrap?.offer?.floor == proposal,
                  meta.bootstrap?.phase == .offered
            else { return false }
            var counters = meta.counters
            for anchor in checkpoint.anchors {
                guard anchor.origin != meta.origin else { throw JournalStoreError.invalidArgument("own origin floor") }
                try ensureOrigin(anchor.origin, counters: &counters)
                guard try originHead(anchor.origin).received == 0,
                      try database.first(
                          "SELECT 1 FROM pending WHERE origin = ? AND sequence <= ?",
                          [.blob(anchor.origin), try JournalDatabase.integer(anchor.sequence)], { _ in true }
                      ) == nil
                else { return false }
                try database.run(
                    "UPDATE origins SET received = ?, head = ? WHERE origin = ?",
                    [try JournalDatabase.integer(anchor.sequence), .blob(anchor.digest), .blob(anchor.origin)]
                )
            }
            try writeCounters(counters)
            try storeFloor(round: round, proposal: proposal, checkpoint: checkpoint, applied: false, meta: meta)
            if let reclamation {
                try storeReclamation(reclamation.frontier, stores: reclamation.stores, applied: false)
            }
            try bumpRevision(meta)
            return true
        }
    }

    private func storeReclamation(_ frontier: [Data: UInt64], stores: [Data], applied: Bool) throws {
        try setSnapshotMeta("reclamationFrontier", .blob(try Self.encodeVector(frontier)))
        try setSnapshotMeta("reclamationStores", .blob(try ReplicaCanonicalJSON.encode(stores.sorted { $0.lexicographicallyPrecedes($1) })))
        try setSnapshotMeta("reclamationApplied", .integer(applied ? 1 : 0))
    }

    // MARK: - Provenance, ancestry and finalization

    /// Records the host's explicit preserving resolution of an ancestry that
    /// does not resolve itself.
    @discardableResult
    func resolveAncestry() throws -> Bool {
        try requireHostOpen()
        return try transaction("resolveAncestry") {
            let meta = try readMeta()
            guard meta.retirement == nil else { throw JournalStoreError.retired }
            guard let ancestry = meta.view.ancestry, !ancestry.resolvesItself, !meta.ancestryResolved else { return false }
            try setSnapshotMeta("ancestryResolved", .integer(1))
            try bumpRevision(meta)
            return true
        }
    }

    /// What this journal's store applied in its group, for the host's next enrollment.
    func lineage() throws -> HostLineageRecord {
        let meta = try readMeta()
        var applied: [Data: UInt64] = [:]
        try database.rows("SELECT origin, applied FROM origins WHERE applied > 0") { applied[try $0.blob(0)] = try $0.unsigned(1) }
        if let retention = meta.retention, retention.floorApplied {
            for anchor in retention.anchors { applied[anchor.origin] = max(applied[anchor.origin] ?? 0, anchor.sequence) }
        }
        applied[meta.origin] = meta.ownHead
        let reclaimed = meta.reclamation.flatMap { $0.applied ? $0.frontier : nil } ?? [:]
        return HostLineageRecord(
            group: meta.group, journalID: meta.journalID, storeID: meta.incarnation?.storeID,
            applied: HostVectorEntry.entries(applied), reclaimedThrough: HostVectorEntry.entries(reclaimed)
        )
    }

    /// The host's fence: with its outbox empty at capture counter
    /// `capturedThrough`, no mutation captured through it will be submitted
    /// again. Mappings of every current own record become releasable once
    /// removed under the floor.
    @discardableResult
    func finalizeSubmissions(capturedThrough: UInt64) throws -> HostJournalFinalizationState {
        try requireResumed()
        return try transaction("finalizeSubmissions") {
            let meta = try readMeta()
            guard meta.retirement == nil else { throw JournalStoreError.retired }
            guard capturedThrough == meta.capturedThrough else { throw JournalStoreError.hostCaptureRegressed }
            let released = meta.finalization?.released ?? 0
            if let fence = meta.finalization, fence.capture >= capturedThrough, fence.own >= meta.ownHead { return fence }
            try setSnapshotMeta("finalizedCapture", try JournalDatabase.integer(capturedThrough))
            try setSnapshotMeta("finalizedOwn", try JournalDatabase.integer(meta.ownHead))
            try setSnapshotMeta("releasedMappings", try JournalDatabase.integer(released))
            try bumpRevision(meta)
            return HostJournalFinalizationState(capture: capturedThrough, own: meta.ownHead, released: released)
        }
    }

    /// Deletes at most `maxMappings` host-mutation mappings of own records
    /// that are both finalized and removed under the floor. Returns how many.
    @discardableResult
    func releaseFinalizedMappings(maxMappings: Int = HostRetentionBounds.pruneStep) throws -> Int {
        guard let fence = view.finalization, let floor = view.retention?.anchor(view.origin)?.sequence, view.retirement == nil else {
            return 0
        }
        let through = min(fence.own, floor)
        return try transaction("releaseFinalizedMappings") {
            let meta = try readMeta()
            var ids: [Data] = []
            try database.rows(
                "SELECT id FROM submissions WHERE sequence <= ? AND sequence NOT IN (SELECT sequence FROM records WHERE origin = ?) LIMIT ?",
                [try JournalDatabase.integer(through), .blob(meta.origin), .integer(Int64(maxMappings))]
            ) { ids.append(try $0.blob(0)) }
            guard !ids.isEmpty else { return 0 }
            for id in ids {
                try database.run("DELETE FROM submissions WHERE id = ?", [.blob(id)])
            }
            try setSnapshotMeta("releasedMappings", try JournalDatabase.integer((meta.finalization?.released ?? 0) + UInt64(ids.count)))
            try bumpRevision(meta)
            return ids.count
        }
    }

    /// The host reclaimed tombstones and clears through the frontier.
    @discardableResult
    func markReclamationApplied(frontier: [Data: UInt64]) throws -> Bool {
        try transaction("markReclamationApplied") {
            let meta = try readMeta()
            guard let reclamation = meta.reclamation, reclamation.frontier == frontier, !reclamation.applied else { return false }
            try setSnapshotMeta("reclamationApplied", .integer(1))
            try bumpRevision(meta)
            return true
        }
    }

    private func storeFloor(round: Data, proposal: Data, checkpoint: HostSnapshotOffer, applied: Bool, meta: Meta) throws {
        try setSnapshotMeta("retentionRound", .blob(round))
        try setSnapshotMeta("retentionProposal", .blob(proposal))
        try setSnapshotMeta("retentionFloor", .blob(try ReplicaCanonicalJSON.encode(checkpoint.anchors)))
        try setSnapshotMeta("retentionCheckpoint", .blob(try ReplicaCanonicalJSON.encode(checkpoint)))
        try setSnapshotMeta("retentionFloorApplied", .integer(applied ? 1 : 0))
        if meta.retention == nil {
            try setSnapshotMeta("prunedRecords", .integer(0))
            try setSnapshotMeta("prunedBytes", .integer(0))
            try setSnapshotMeta("prunedPositions", .integer(0))
        }
    }

    /// The installed checkpoint reflects the floor's records, so each origin's
    /// applied sequence starts at least at its anchor.
    private func markFloorApplied(_ retention: HostJournalRetentionState) throws {
        for anchor in retention.anchors {
            try database.run(
                "UPDATE origins SET applied = MAX(applied, ?) WHERE origin = ?",
                [try JournalDatabase.integer(anchor.sequence), .blob(anchor.origin)]
            )
        }
        try setSnapshotMeta("retentionFloorApplied", .integer(1))
    }

    private func setSnapshotRefusal(_ reason: HostSnapshotRefusalReason) throws {
        try setSnapshotMeta("snapshotRefusal", .text(reason.rawValue))
        try setSnapshotMeta("snapshotPhase", .text(HostSnapshotPhase.refused.rawValue))
    }

    func setHistoryProvider(_ member: Data) throws {
        guard member.count == 32 else { throw JournalStoreError.invalidArgument("provider") }
        try transaction("setHistoryProvider") {
            let meta = try readMeta()
            guard meta.retirement == nil else { throw JournalStoreError.retired }
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

    nonisolated static func encodeVector(_ vector: [Data: UInt64]) throws -> Data {
        var data = Data()
        for (origin, sequence) in vector.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
            guard origin.count == JournalEnvelope.originLength, sequence >= 1, sequence <= JournalEnvelope.maxSequence else {
                throw JournalStoreError.invalidArgument("vector")
            }
            data.append(origin)
            withUnsafeBytes(of: sequence.bigEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    nonisolated static func decodeVector(_ data: Data) throws -> [Data: UInt64] {
        let entry = JournalEnvelope.originLength + 8
        guard data.count % entry == 0, data.count / entry <= 1_024 else { throw JournalStoreError.storeCorrupt("vector") }
        let bytes = Data(data)
        var vector: [Data: UInt64] = [:]
        var previous: Data?
        for offset in stride(from: 0, to: bytes.count, by: entry) {
            let origin = bytes.subdata(in: offset..<offset + JournalEnvelope.originLength)
            let sequence = bytes.subdata(in: offset + JournalEnvelope.originLength..<offset + entry).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            guard sequence >= 1, sequence <= JournalEnvelope.maxSequence,
                  previous.map({ $0.lexicographicallyPrecedes(origin) }) ?? true
            else { throw JournalStoreError.storeCorrupt("vector") }
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
            guard message.sender.count == 32 else { throw JournalStoreError.invalidArgument("sender") }
            _ = try JournalDatabase.integer(message.cursor)
        }
        try transaction("retire") {
            let meta = try readMeta()
            guard meta.retirement == nil else { throw JournalStoreError.retired }
            var counters = meta.counters
            for message in heldInbox {
                let digest = Data(SHA256.hash(data: message.plaintext))
                let key: [JournalValue] = [.blob(message.sender), try JournalDatabase.integer(message.cursor)]
                if let existing = try database.first(
                    "SELECT digest FROM heldInbox WHERE sender = ? AND cursor = ?", key, { try $0.blob(0) }
                ) {
                    guard existing == digest else {
                        throw JournalStoreError.heldInboxConflict(sender: message.sender, cursor: message.cursor)
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

    /// Whether this retired journal holds every one of `messages` with the
    /// same bytes, which proves an earlier handoff took them over.
    func holdsInbox(_ messages: [HostJournalHeldMessage]) throws -> Bool {
        guard view.isRetired else { return false }
        try database.execute("BEGIN")
        defer { try? database.execute("COMMIT") }
        for message in messages {
            let key: [JournalValue] = [.blob(message.sender), try JournalDatabase.integer(message.cursor)]
            let stored = try database.first("SELECT plaintext FROM heldInbox WHERE sender = ? AND cursor = ?", key, { try $0.blob(0) })
            guard stored == message.plaintext else { return false }
        }
        return true
    }

    /// Refuses host work from now on, for this handle only.
    func fenceHost() {
        isHostFenced = true
    }

    /// Carries a resume this process confirmed on an earlier connection to
    /// this file: only for the same confirmed enrollment of an active,
    /// unfenced journal.
    func adoptResumption(enrollmentID: Data) {
        guard case .confirmed(let confirmed) = view.enrollment, confirmed == enrollmentID, !view.isRetired, !isHostFenced else {
            return
        }
        isResumed = true
    }

    private func requireHostOpen() throws {
        if view.isRetired { throw JournalStoreError.retired }
        if isHostFenced { throw JournalStoreError.fenced }
    }

    private func requireResumed() throws {
        try requireHostOpen()
        guard isResumed else { throw view.isRetired ? JournalStoreError.retired : JournalStoreError.notResumed }
    }

    // MARK: - Transactions

    enum ProofEffect: Sendable {
        /// Leaves remote records, pending rows, origin heads and the
        /// generation as they were.
        case none
        /// Changes rows a window proof reads.
        case intake
        /// Ends this generation.
        case generation
    }

    /// Every transaction, and whether a window proof must be redone after it.
    /// Submission only appends own records and raises `ownHead`, which a
    /// proof treats as monotone.
    static let proofEffects: [String: ProofEffect] = [
        "enroll": .none, "resume": .none, "submit": .none, "markApplied": .none, "markEstablished": .none,
        "declareReady": .none, "recordCompletionTarget": .none, "setHistoryProvider": .none,
        "enterControlRepair": .none, "intake": .intake, "promote": .intake, "retire": .generation,
        "requestSnapshot": .none, "refuseSnapshot": .none, "advanceSnapshot": .none, "commitSnapshotInstall": .none,
        "commitRetentionFloor": .intake, "pruneBelowFloor": .intake, "adoptRetentionFloor": .intake,
        "resolveAncestry": .none, "finalizeSubmissions": .none, "releaseFinalizedMappings": .none,
        "markReclamationApplied": .none,
    ]

    /// Builds the snapshot this commit leaves before COMMIT, so nothing
    /// fallible runs after it.
    private func transaction<T>(_ name: String, _ body: () throws -> T) throws -> T {
        guard let effect = Self.proofEffects[name] else { throw JournalStoreError.invalidArgument("transaction \(name)") }
        try database.execute("BEGIN IMMEDIATE")
        let result: T
        let committed: HostJournalSnapshot
        do {
            result = try body()
            committed = try makeSnapshot(
                view: readMeta().view, sequence: snapshot.commitSequence + 1,
                epoch: effect == .none ? intakeEpoch : intakeEpoch &+ 1
            )
            try faultHookForTesting?(.beforeCommit(name))
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
        snapshot = committed
        try faultHookForTesting?(.afterCommit(name))
        return result
    }

    private func makeSnapshot(view: HostJournalCoreView, sequence: UInt64, epoch: UInt64) throws -> HostJournalSnapshot {
        var origins: [Data] = []
        var received: [Data: UInt64] = [:]
        try database.rows("SELECT origin, received FROM origins ORDER BY origin") { row in
            let origin = try row.blob(0)
            origins.append(origin)
            let head = try row.unsigned(1)
            if head > 0 { received[origin] = head }
        }
        let promotable = try database.first(
            "SELECT 1 FROM pending JOIN origins ON pending.origin = origins.origin AND pending.sequence = origins.received + 1 LIMIT 1",
            [], { _ in true }
        ) ?? false
        return HostJournalSnapshot(
            generation: generation, commitSequence: sequence, view: view, origins: origins, received: received,
            hasPromotable: promotable, intakeEpoch: epoch
        )
    }

    private func bumpRevision(_ meta: Meta) throws {
        try setMeta("revision", try JournalDatabase.integer(meta.revision + 1))
    }

    private func setMeta(_ key: String, _ value: JournalValue) throws {
        try database.run("UPDATE meta SET value = ? WHERE key = ?", [value, .text(key)])
    }

    /// Snapshot keys exist only once a bootstrap was requested.
    private func setSnapshotMeta(_ key: String, _ value: JournalValue) throws {
        precondition(["snapshot", "retention", "pruned", "incarnation", "ancestry", "reclamation", "finalized", "released"]
            .contains { key.hasPrefix($0) })
        try database.run("INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [.text(key), value])
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
                guard let value = values[key] else { throw JournalStoreError.storeCorrupt("missing \(key)") }
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
        let bootstrap: HostJournalBootstrapState?
        let retention: HostJournalRetentionState?
        let incarnation: HostStoreIncarnationRecord?
        let ancestryResolved: Bool
        let reclamation: HostJournalReclamationState?
        let finalization: HostJournalFinalizationState?

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
                historyProvider: historyProvider, controlRepair: controlRepair, bootstrap: bootstrap,
                retention: retention, incarnation: incarnation, ancestryResolved: ancestryResolved,
                reclamation: reclamation, finalization: finalization
            )
        }
    }

    nonisolated static func readMeta(_ database: JournalDatabase) throws -> Meta {
        var blobs: [String: Data] = [:]
        var texts: [String: String] = [:]
        var integers: [String: UInt64] = [:]
        try database.rows("SELECT key, value, typeof(value) FROM meta") { row in
            let key = try row.text(0)
            switch try row.text(2) {
            case "blob": blobs[key] = try row.blob(1)
            case "text": texts[key] = try row.text(1)
            case "integer": integers[key] = try row.unsigned(1)
            default: throw JournalStoreError.storeCorrupt("meta \(key)")
            }
        }
        func blob(_ key: String, _ length: Int?) throws -> Data {
            guard let value = blobs[key], length.map({ value.count == $0 }) ?? true else {
                throw JournalStoreError.storeCorrupt("meta \(key)")
            }
            return value
        }
        func integer(_ key: String) throws -> UInt64 {
            guard let value = integers[key] else { throw JournalStoreError.storeCorrupt("meta \(key)") }
            return value
        }
        let retirement: HostJournalRetirement?
        switch texts["retirement"] {
        case "active": retirement = nil
        case .some(let raw):
            guard let reason = HostJournalRetirement(rawValue: raw) else { throw JournalStoreError.storeCorrupt("retirement") }
            retirement = reason
        case nil: throw JournalStoreError.storeCorrupt("retirement")
        }
        let enrollmentID = try blob("enrollmentID", nil)
        let enrollment: HostJournalEnrollment
        switch texts["enrollment"] {
        case "none" where enrollmentID.isEmpty: enrollment = .none
        case "pending" where enrollmentID.count == 16: enrollment = .pending(enrollmentID)
        case "confirmed" where enrollmentID.count == 16: enrollment = .confirmed(enrollmentID)
        default: throw JournalStoreError.storeCorrupt("enrollment")
        }
        let nextPosition = try integer("nextPosition")
        let appliedThrough = try integer("appliedThrough")
        let completionPosition = try integer("completionPosition")
        guard nextPosition >= 1, appliedThrough < nextPosition, completionPosition < nextPosition else {
            throw JournalStoreError.storeCorrupt("positions")
        }
        func flag(_ key: String) throws -> Bool {
            switch try integer(key) {
            case 0: return false
            case 1: return true
            default: throw JournalStoreError.storeCorrupt("meta \(key)")
            }
        }
        func member(_ key: String) throws -> Data? {
            let value = try blob(key, nil)
            guard value.isEmpty || value.count == 32 else { throw JournalStoreError.storeCorrupt("meta \(key)") }
            return value.isEmpty ? nil : value
        }
        let target = try blob("completionTarget", nil)
        let historyComplete = try flag("historyComplete")
        let bootstrap = try readBootstrap(texts: texts, blobs: blobs)
        let retention = try readRetention(blobs: blobs, integers: integers)
        let incarnation = try blobs["incarnation"].map { bytes -> HostStoreIncarnationRecord in
            let decoded = try ReplicaCanonicalJSON.decode(HostStoreIncarnationRecord.self, from: bytes)
            guard decoded.isWellFormed else { throw JournalStoreError.storeCorrupt("incarnation") }
            return decoded
        }
        let reclamation = try blobs["reclamationFrontier"].map { bytes -> HostJournalReclamationState in
            guard let stores = blobs["reclamationStores"], let applied = integers["reclamationApplied"], applied <= 1 else {
                throw JournalStoreError.storeCorrupt("reclamation")
            }
            let state = HostJournalReclamationState(
                frontier: try decodeVector(bytes), stores: try ReplicaCanonicalJSON.decode([Data].self, from: stores), applied: applied == 1
            )
            guard let retention, state.isWellFormed(at: retention.anchors) else {
                throw JournalStoreError.storeCorrupt("reclamation")
            }
            return state
        }
        if reclamation == nil, blobs["reclamationStores"] != nil || integers["reclamationApplied"] != nil {
            throw JournalStoreError.storeCorrupt("reclamation")
        }
        let finalization = integers["finalizedCapture"].map {
            HostJournalFinalizationState(capture: $0, own: integers["finalizedOwn"] ?? 0, released: integers["releasedMappings"] ?? 0)
        }
        return Meta(
            journalID: try blob("journalID", 16), group: try blob("group", 32), origin: try blob("origin", 16),
            retirement: retirement, revision: try integer("revision"), enrollment: enrollment,
            capturedThrough: try integer("capturedThrough"), appliedThrough: appliedThrough,
            nextPosition: nextPosition, ownHead: try integer("ownHead"), counters: try Counters(integers),
            established: try flag("established"), isReady: try flag("ready"), readyThrough: try integer("readyThrough"),
            historyComplete: historyComplete, completionProvider: try member("completionProvider"),
            completionTarget: target.isEmpty ? nil : try decodeVector(target),
            completionPosition: completionPosition, historyProvider: try member("historyProvider"),
            controlRepair: try flag("controlRepair"), bootstrap: bootstrap, retention: retention,
            incarnation: incarnation, ancestryResolved: (integers["ancestryResolved"] ?? 0) == 1,
            reclamation: reclamation, finalization: finalization
        )
    }

    /// Absent keys mean no floor was committed or adopted.
    nonisolated private static func readRetention(blobs: [String: Data], integers: [String: UInt64]) throws -> HostJournalRetentionState? {
        guard let round = blobs["retentionRound"] else { return nil }
        guard let proposal = blobs["retentionProposal"], let anchorBytes = blobs["retentionFloor"],
              let checkpointBytes = blobs["retentionCheckpoint"], let applied = integers["retentionFloorApplied"],
              round.count == 16, proposal.count == 32, applied <= 1
        else { throw JournalStoreError.storeCorrupt("retention") }
        let anchors = try ReplicaCanonicalJSON.decode([HostSnapshotAnchor].self, from: anchorBytes)
        let checkpoint = try ReplicaCanonicalJSON.decode(HostSnapshotOffer.self, from: checkpointBytes)
        guard !anchors.isEmpty, checkpoint.isWellFormed, checkpoint.anchors == anchors,
              zip(anchors, anchors.dropFirst()).allSatisfy({ $0.origin.lexicographicallyPrecedes($1.origin) })
        else { throw JournalStoreError.storeCorrupt("retention") }
        let pruned = integers["prunedRecords"] ?? 0
        let positions = integers["prunedPositions"] ?? 0
        guard positions <= pruned else { throw JournalStoreError.storeCorrupt("retention") }
        return HostJournalRetentionState(
            round: round, proposal: proposal, anchors: anchors, checkpoint: checkpoint, floorApplied: applied == 1,
            prunedRecords: pruned, prunedBytes: integers["prunedBytes"] ?? 0, prunedPositions: positions
        )
    }

    /// Absent keys mean no bootstrap was requested. Present ones must be
    /// complete and consistent with their phase.
    nonisolated private static func readBootstrap(texts: [String: String], blobs: [String: Data]) throws -> HostJournalBootstrapState? {
        guard let rawPhase = texts["snapshotPhase"] else { return nil }
        guard let phase = HostSnapshotPhase(rawValue: rawPhase), let schema = texts["snapshotSchema"],
              HostSnapshotSchemaName.isValid(schema)
        else { throw JournalStoreError.storeCorrupt("snapshot") }
        let offer = try blobs["snapshotOffer"].map { try ReplicaCanonicalJSON.decode(HostSnapshotOffer.self, from: $0) }
        let refusal = try texts["snapshotRefusal"].map { raw in
            guard let reason = HostSnapshotRefusalReason(rawValue: raw) else { throw JournalStoreError.storeCorrupt("snapshot") }
            return reason
        }
        let coverage = try blobs["snapshotCoverage"].map(decodeVector)
        let needsOffer = phase != .requested && phase != .refused
        guard offer.map(\.isWellFormed) ?? true, !needsOffer || offer != nil, (refusal != nil) == (phase == .refused),
              (coverage != nil) == (phase == .installed || phase == .completed),
              coverage.map({ $0 == offer?.coverage }) ?? true
        else { throw JournalStoreError.storeCorrupt("snapshot") }
        return HostJournalBootstrapState(phase: phase, schema: schema, offer: offer, refusal: refusal, coverage: coverage)
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

    nonisolated static func requireRegularFile(_ url: URL) throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw JournalStoreError.storeMissing
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw JournalStoreError.storeUnreadable("not a regular file")
        }
    }

    nonisolated static func checkFormat(_ database: JournalDatabase) throws {
        let version = try database.first("PRAGMA user_version", [], { try $0.int64(0) }) ?? 0
        guard version == formatVersion || version == compactedFormatVersion else { throw JournalStoreError.formatUnsupported(version) }
    }

    /// Checks every row against its own bytes, the per-origin chains, the
    /// position sequence, the mappings and the stored counters.
    nonisolated static func validate(
        _ database: JournalDatabase, cancellation: HostJournalCancellation? = nil
    ) throws -> HostJournalCoreView {
        if Thread.isMainThread {
            mainThreadValidations.withLock { $0 += 1 }
        }
        var rowsSinceCheck = 0
        func checkCancellation() throws {
            rowsSinceCheck += 1
            guard rowsSinceCheck >= 1_024 else { return }
            rowsSinceCheck = 0
            if cancellation?.isCancelled == true { throw CancellationError() }
        }
        guard try database.first("PRAGMA quick_check", [], { try $0.text(0) }) == "ok" else {
            throw JournalStoreError.storeCorrupt("quick_check")
        }
        let meta = try readMeta(database)
        var counters = Counters()
        var heads: [Data: (received: UInt64, digest: Data)] = [:]
        var lastPositions: [Data: UInt64] = [:]
        var positions: UInt64 = 0
        var maxPosition: UInt64 = 0
        var ownPayloads: [UInt64: Data] = [:]
        try database.rows("SELECT origin, sequence, envelope, digest, position FROM records ORDER BY origin, sequence") { row in
            try checkCancellation()
            let envelope = try stored(try row.blob(2))
            let origin = try row.blob(0)
            let sequence = try row.unsigned(1)
            let anchor = meta.retention?.anchor(origin)
            var previous = heads[origin] ?? (0, JournalEnvelope.zeroDigest)
            if heads[origin] == nil, let anchor, sequence > 1 {
                // Records below the first retained one were removed under the floor.
                guard sequence <= anchor.sequence + 1 else { throw JournalStoreError.storeCorrupt("record chain") }
                previous = sequence == anchor.sequence + 1 ? (anchor.sequence, anchor.digest) : (sequence - 1, envelope.prior)
            }
            guard envelope.origin == origin, envelope.sequence == sequence, envelope.digest == (try row.blob(3)),
                  sequence == previous.received + 1, envelope.prior == previous.digest,
                  anchor.map({ $0.sequence != sequence || $0.digest == envelope.digest }) ?? true
            else { throw JournalStoreError.storeCorrupt("record chain") }
            heads[origin] = (sequence, envelope.digest)
            if origin == meta.origin {
                guard row.isNull(4) else { throw JournalStoreError.storeCorrupt("own position") }
                ownPayloads[sequence] = Data(SHA256.hash(data: envelope.payload))
            } else {
                let position = try row.unsigned(4)
                guard position >= 1, position > lastPositions[origin] ?? 0 else {
                    throw JournalStoreError.storeCorrupt("position order")
                }
                lastPositions[origin] = position
                positions += 1
                maxPosition = max(maxPosition, position)
            }
            counters.recordCount += 1
            counters.recordBytes += UInt64(envelope.bytes.count)
        }
        for anchor in meta.retention?.anchors ?? [] where (heads[anchor.origin]?.received ?? 0) < anchor.sequence {
            guard heads[anchor.origin] == nil else { throw JournalStoreError.storeCorrupt("record chain") }
            heads[anchor.origin] = (anchor.sequence, anchor.digest)
        }
        let prunedPositions = meta.retention?.prunedPositions ?? 0
        guard positions + prunedPositions == meta.nextPosition - 1, maxPosition <= meta.nextPosition - 1,
              prunedPositions > 0 || maxPosition == positions,
              (heads[meta.origin]?.received ?? 0) == meta.ownHead
        else { throw JournalStoreError.storeCorrupt("positions") }
        var applied: [Data: UInt64] = [:]
        try database.rows(
            "SELECT origin, MAX(sequence) FROM records WHERE position IS NOT NULL AND position <= ? GROUP BY origin",
            [try JournalDatabase.integer(meta.appliedThrough)]
        ) { applied[try $0.blob(0)] = try $0.unsigned(1) }
        if let retention = meta.retention, retention.floorApplied {
            for anchor in retention.anchors where anchor.origin != meta.origin {
                applied[anchor.origin] = max(applied[anchor.origin] ?? 0, anchor.sequence)
            }
        }
        try database.rows("SELECT origin, received, head, applied FROM origins") { row in
            let origin = try row.blob(0)
            let head = heads[origin] ?? (0, JournalEnvelope.zeroDigest)
            guard origin.count == 16, try row.unsigned(1) == head.received, try row.blob(2) == head.digest,
                  try row.unsigned(3) == (origin == meta.origin ? 0 : applied[origin] ?? 0)
            else { throw JournalStoreError.storeCorrupt("origin \(origin.count)") }
            counters.originCount += 1
        }
        let knownOrigins = try originSet(database)
        guard Set(heads.keys).isSubset(of: knownOrigins), knownOrigins.contains(meta.origin) else {
            throw JournalStoreError.storeCorrupt("origins")
        }
        var mappings: UInt64 = 0
        try database.rows("SELECT id, sequence, payloadDigest FROM submissions") { row in
            let sequence = try row.unsigned(1)
            let removed = sequence <= (meta.retention?.anchor(meta.origin)?.sequence ?? 0) && ownPayloads[sequence] == nil
            let payloadDigest = try row.blob(2)
            guard try row.blob(0).count == 16, removed || ownPayloads[sequence] == payloadDigest else {
                throw JournalStoreError.storeCorrupt("submission")
            }
            mappings += 1
        }
        guard mappings + (meta.finalization?.released ?? 0) == meta.ownHead else { throw JournalStoreError.storeCorrupt("submissions") }
        try database.rows("SELECT origin, sequence, envelope, digest FROM pending") { row in
            try checkCancellation()
            let envelope = try stored(try row.blob(2))
            let received = heads[envelope.origin]?.received ?? 0
            guard envelope.origin == (try row.blob(0)), envelope.sequence == (try row.unsigned(1)),
                  envelope.digest == (try row.blob(3)), envelope.sequence > received, envelope.origin != meta.origin,
                  knownOrigins.contains(envelope.origin)
            else { throw JournalStoreError.storeCorrupt("pending") }
            counters.pendingCount += 1
            counters.pendingBytes += UInt64(envelope.bytes.count)
        }
        for (table, column) in [("quarantine", "bytes"), ("heldInbox", "plaintext")] {
            try database.rows("SELECT sender, \(column), digest, cursor FROM \(table)") { row in
                let bytes = try row.blob(1)
                guard try row.blob(0).count == 32, Data(SHA256.hash(data: bytes)) == (try row.blob(2)),
                      try row.int64(3) >= 0
                else {
                    throw JournalStoreError.storeCorrupt(table)
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
        guard counters == meta.counters else { throw JournalStoreError.storeCorrupt("counters") }
        if meta.historyComplete, let target = meta.completionTarget {
            guard target.allSatisfy({ (heads[$0.key]?.received ?? 0) >= $0.value }) else {
                throw JournalStoreError.storeCorrupt("completion")
            }
        }
        guard meta.readyThrough <= meta.capturedThrough else { throw JournalStoreError.storeCorrupt("ready") }
        if let coverage = meta.bootstrap?.coverage {
            guard coverage.allSatisfy({ (heads[$0.key]?.received ?? 0) >= $0.value }) else {
                throw JournalStoreError.storeCorrupt("snapshot coverage")
            }
        }
        return meta.view
    }

    nonisolated private static func originSet(_ database: JournalDatabase) throws -> Set<Data> {
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
    nonisolated static func stored(_ bytes: Data) throws -> JournalEnvelope {
        do {
            return try JournalEnvelope(parsing: bytes)
        } catch {
            throw JournalStoreError.storeCorrupt("envelope: \(error)")
        }
    }

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
