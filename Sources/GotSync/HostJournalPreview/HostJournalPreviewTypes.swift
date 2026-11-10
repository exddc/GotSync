import Foundation

/// A host-chosen identifier of one mutation; resubmitting the same ID with
/// the same payload returns the same record.
@_spi(HostJournalPreview) public struct HostMutationID: Hashable, Codable, Sendable {
    public let uuid: UUID

    public init(_ uuid: UUID) {
        self.uuid = uuid
    }

    init(bytes: Data) {
        var raw = [UInt8](repeating: 0, count: 16)
        for (index, byte) in bytes.prefix(16).enumerated() { raw[index] = byte }
        uuid = UUID(uuid: (
            raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
            raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]
        ))
    }

    var bytes: Data {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }
}

/// One record: its origin and its sequence within that origin.
@_spi(HostJournalPreview) public struct HostRecordID: Hashable, Sendable {
    public let origin: Data
    public let sequence: UInt64

    init(_ id: JournalRecordID) {
        origin = id.origin
        sequence = id.sequence
    }
}

/// A position in the journal's delivery order. Always positive and within
/// the storage range; "nothing" is expressed as nil, never as zero.
@_spi(HostJournalPreview) public struct JournalPosition: Comparable, Hashable, Codable, Sendable {
    public let rawValue: UInt64

    /// Nil for zero and for values beyond the storage range.
    public init?(rawValue: UInt64) {
        guard rawValue > 0, rawValue <= UInt64(Int64.max) else { return nil }
        self.rawValue = rawValue
    }

    /// A stored position, or nil for the stored zero that means none.
    static func stored(_ value: UInt64) -> JournalPosition? {
        JournalPosition(rawValue: value)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let position = JournalPosition(rawValue: try container.decode(UInt64.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "journal position out of range")
        }
        self = position
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: JournalPosition, rhs: JournalPosition) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// What the host saves with its business state and presents on every
/// launch. `capturedThrough` is the host's own capture counter, saved with
/// its outbox before submission.
@_spi(HostJournalPreview) public struct HostProvenance: Codable, Hashable, Sendable {
    public let journalID: Data
    public let enrollmentID: Data
    /// The last position applied to the host's business state; nil for none.
    public let appliedThrough: JournalPosition?
    public let capturedThrough: UInt64

    public init(journalID: Data, enrollmentID: Data, appliedThrough: JournalPosition?, capturedThrough: UInt64) {
        self.journalID = journalID
        self.enrollmentID = enrollmentID
        self.appliedThrough = appliedThrough
        self.capturedThrough = capturedThrough
    }

    init(_ stored: HostJournalProvenance) {
        journalID = stored.journalID
        enrollmentID = stored.enrollmentID
        appliedThrough = JournalPosition.stored(stored.appliedThrough)
        capturedThrough = stored.capturedThrough
    }

    var stored: HostJournalProvenance {
        HostJournalProvenance(
            journalID: journalID, enrollmentID: enrollmentID,
            appliedThrough: appliedThrough?.rawValue ?? 0, capturedThrough: capturedThrough
        )
    }
}

@_spi(HostJournalPreview) public struct HostMutation: Sendable {
    public let id: HostMutationID
    public let payload: Data

    public init(id: HostMutationID, payload: Data) {
        self.id = id
        self.payload = payload
    }
}

/// A remote record in delivery order.
@_spi(HostJournalPreview) public struct IncomingRecord: Sendable {
    public let position: JournalPosition
    public let record: HostRecordID
    public let payload: Data

    init?(_ incoming: HostJournalIncoming) {
        guard let position = JournalPosition(rawValue: incoming.position) else { return nil }
        self.position = position
        record = HostRecordID(incoming.record)
        payload = incoming.payload
    }
}

// MARK: - State

@_spi(HostJournalPreview) public enum HostEnrollmentState: Equatable, Sendable {
    case none
    case pending
    case confirmed
}

@_spi(HostJournalPreview) public enum HostClosingIntent: Equatable, Sendable {
    case unlink
    case removed
    case erase

    init(_ intent: HostLifecycleIntent) {
        switch intent {
        case .unlink: self = .unlink
        case .removed: self = .removed
        case .erase: self = .erase
        }
    }
}

@_spi(HostJournalPreview) public enum HostJournalLifecycle: Equatable, Sendable {
    case opening
    case active
    case closing(HostClosingIntent)
    case failed(HostClosingIntent)

    init(_ lifecycle: HostLifecycle) {
        switch lifecycle {
        case .opening: self = .opening
        case .active: self = .active
        case .closing(let intent): self = .closing(HostClosingIntent(intent))
        case .failed(let intent): self = .failed(HostClosingIntent(intent))
        }
    }
}

/// Inbox messages the journal does not own yet; unknown while MLS work may
/// have changed the inbox since the last settled cycle.
@_spi(HostJournalPreview) public enum HostIntakeState: Equatable, Sendable {
    case unknown
    case settled(held: Int)
}

@_spi(HostJournalPreview) public enum HostRetirementReason: Equatable, Sendable {
    case unlink
    case removed
    case orphaned

    init(_ retirement: HostJournalRetirement) {
        switch retirement {
        case .unlink: self = .unlink
        case .removed: self = .removed
        case .orphaned: self = .orphaned
        }
    }
}

/// The committed state of the bound journal generation.
@_spi(HostJournalPreview) public struct HostJournalState: Equatable, Sendable {
    public let journalID: Data
    public let group: Data
    public let enrollment: HostEnrollmentState
    public let retirement: HostRetirementReason?
    public let isReady: Bool
    public let readyThrough: UInt64
    public let capturedThrough: UInt64
    public let appliedThrough: JournalPosition?
    public let delivered: JournalPosition?
    public let undelivered: UInt64
    public let uploadedThrough: UInt64
    public let unuploaded: UInt64
    public let historyComplete: Bool
    public let historyApplied: Bool
    public let pendingCount: UInt64
    public let quarantineCount: UInt64
    public let heldCount: UInt64
    public let retainedCount: UInt64
    public let retainedBytes: UInt64
    public let controlRepair: Bool
}

/// The composed host view. `journal` is nil while no generation is bound,
/// for example while opening or after a failure, so nothing is invented.
@_spi(HostJournalPreview) public struct HostJournalView: Equatable, Sendable {
    /// Rises with every change; a new value means "read again".
    public let revision: UInt64
    public let lifecycle: HostJournalLifecycle
    public let repair: HostJournalRepair?
    public let intake: HostIntakeState
    /// No accepted journal call is still waiting for its outcome.
    public let journalSettled: Bool
    public let isQuiescent: Bool
    public let journal: HostJournalState?

    init(_ view: HostEngineView) {
        revision = view.revision
        lifecycle = HostJournalLifecycle(view.lifecycle)
        repair = view.repair.map(HostJournalRepair.init)
        switch view.intake {
        case .unknown: intake = .unknown
        case .settled(let held): intake = .settled(held: held)
        }
        journalSettled = view.journalSettled
        isQuiescent = view.isQuiescent
        journal = view.journal.map { core in
            let enrollment: HostEnrollmentState
            switch core.enrollment {
            case .none: enrollment = .none
            case .pending: enrollment = .pending
            case .confirmed: enrollment = .confirmed
            }
            return HostJournalState(
                journalID: core.journalID, group: core.group, enrollment: enrollment,
                retirement: core.retirement.map(HostRetirementReason.init),
                isReady: core.isReady, readyThrough: core.readyThrough, capturedThrough: core.capturedThrough,
                appliedThrough: JournalPosition.stored(core.appliedThrough), delivered: JournalPosition.stored(core.delivered),
                undelivered: core.undelivered, uploadedThrough: view.uploadedThrough, unuploaded: view.unuploaded,
                historyComplete: core.historyComplete, historyApplied: core.historyApplied,
                pendingCount: core.pendingCount, quarantineCount: core.quarantineCount, heldCount: core.heldCount,
                retainedCount: core.retainedCount, retainedBytes: core.retainedBytes, controlRepair: core.controlRepair
            )
        }
    }
}

// MARK: - Invitation phrase

@_spi(HostJournalPreview) extension Invitation {
    /// Words in an invitation phrase, as the phrase codec defines it.
    public static var phraseWordCount: Int { MnemonicCodec.wordCount }
}

// MARK: - Submission limits

/// What one journal accepts per mutation and per `submit` call, so a host
/// can size its batches without guessing the wire overhead.
@_spi(HostJournalPreview) public struct HostSubmissionLimits: Equatable, Sendable {
    /// The largest `HostMutation.payload`.
    public let maxPayloadBytes: Int
    /// Bytes each mutation adds to its payload once encoded as an envelope.
    public let envelopeOverheadBytes: Int
    /// The most mutations one `submit` call may carry.
    public let maxRecordsPerSubmit: Int
    /// The most encoded envelope bytes, overhead included, one `submit` call may carry.
    public let maxEncodedBytesPerSubmit: Int

    init(_ limits: HostJournalLimits) {
        maxPayloadBytes = JournalEnvelope.maxPayloadLength
        envelopeOverheadBytes = JournalEnvelope.headerLength
        maxRecordsPerSubmit = limits.batch
        maxEncodedBytesPerSubmit = limits.submitCallBytes
    }
}

// MARK: - Errors

@_spi(HostJournalPreview) public enum HostJournalCapacity: Equatable, Sendable {
    /// One `submit` call's encoded envelopes exceed `limit` bytes.
    case submitCallTooLarge(limit: Int)
    case submitBudget
    case history
    case pending
    case quarantine
    case origins
    case retiredJournals

    init(_ capacity: JournalCapacity) {
        switch capacity {
        case .submitCallTooLarge(let limit): self = .submitCallTooLarge(limit: limit)
        case .submitBudget: self = .submitBudget
        case .history: self = .history
        case .pending: self = .pending
        case .quarantine: self = .quarantine
        case .origins: self = .origins
        }
    }
}

/// Why host work stopped preserving everything. No diagnostic text is
/// carried, only the typed reason.
@_spi(HostJournalPreview) public enum HostJournalRepair: Equatable, Sendable {
    case journalMissing
    case journalUnreadable
    case journalCorrupt
    case journalFormat
    case ambiguousJournal
    case mlsUnreadable
    case lifecycleUnreadable
    case launchFailed
    case launchInputsChanged
    case sessionCloseUncertain
    case handoffUnproven
    case hostProvenanceMissing
    case hostProvenanceMismatch
    case hostCaptureRegressed
    case hostApplicationRegressed
    case fork(origin: Data, sequence: UInt64)
    case foreignOwnOrigin(sequence: UInt64)
    case retainedRecordMissing(origin: Data, sequence: UInt64)
    case inboxConflict(sender: Data, cursor: UInt64)

    init(_ repair: HostRepair) {
        switch repair {
        case .journalMissing: self = .journalMissing
        case .journalUnreadable: self = .journalUnreadable
        case .ambiguousJournal: self = .ambiguousJournal
        case .mlsUnreadable: self = .mlsUnreadable
        case .lifecycleUnreadable: self = .lifecycleUnreadable
        case .launchFailed: self = .launchFailed
        case .launchInputsChanged: self = .launchInputsChanged
        case .sessionCloseUncertain: self = .sessionCloseUncertain
        }
    }
}

@_spi(HostJournalPreview) public enum HostJournalError: Error, Equatable, Sendable {
    /// This handle's generation was fenced or closed; read `hostJournal` again.
    case fenced
    case retired
    /// `resume` has not succeeded in this process for this journal.
    case notResumed
    case enrollmentRequired
    case staleJournal
    case notReady
    case unsettledJoin
    case hostMutationConflict(HostMutationID)
    case payloadTooLarge(Int)
    case invalidArgument
    case positionOutOfRange
    case capacity(HostJournalCapacity)
    case repairRequired(HostJournalRepair)
    case notArchived
    case confirmationMismatch
    case exportCursorMismatch
    case exportRevisionChanged
    /// The journal file could not be read or written; details stay internal.
    case storageUnavailable

    /// The public form of any error a host call can raise. Cancellation
    /// passes through unchanged.
    static func surfaced(_ error: any Error) -> any Error {
        switch error {
        case is CancellationError: error
        case let error as HostJournalError: error
        case let error as JournalStoreError: HostJournalError(error)
        case let error as HostEngineError: HostJournalError(error)
        default: HostJournalError.storageUnavailable
        }
    }

    init(_ error: JournalStoreError) {
        switch error {
        case .storage, .storeExists, .proofStale: self = .storageUnavailable
        case .valueOutOfRange, .invalidArgument: self = .invalidArgument
        case .storeMissing: self = .repairRequired(.journalMissing)
        case .storeUnreadable: self = .repairRequired(.journalUnreadable)
        case .formatUnsupported: self = .repairRequired(.journalFormat)
        case .storeCorrupt: self = .repairRequired(.journalCorrupt)
        case .retired: self = .retired
        case .fenced: self = .fenced
        case .notResumed: self = .notResumed
        case .enrollmentRequired: self = .enrollmentRequired
        case .staleJournal: self = .staleJournal
        case .hostProvenanceMissing: self = .repairRequired(.hostProvenanceMissing)
        case .hostProvenanceMismatch: self = .repairRequired(.hostProvenanceMismatch)
        case .hostCaptureRegressed: self = .repairRequired(.hostCaptureRegressed)
        case .hostApplicationRegressed: self = .repairRequired(.hostApplicationRegressed)
        case .positionOutOfRange: self = .positionOutOfRange
        case .payloadTooLarge(let size): self = .payloadTooLarge(size)
        case .hostMutationConflict(let id): self = .hostMutationConflict(HostMutationID(bytes: id))
        case .capacity(let capacity): self = .capacity(HostJournalCapacity(capacity))
        case .fork(let origin, let sequence): self = .repairRequired(.fork(origin: origin, sequence: sequence))
        case .retainedRecordMissing(let origin, let sequence):
            self = .repairRequired(.retainedRecordMissing(origin: origin, sequence: sequence))
        case .foreignOwnOrigin(let sequence): self = .repairRequired(.foreignOwnOrigin(sequence: sequence))
        case .quarantineConflict(let sender, let cursor), .heldInboxConflict(let sender, let cursor):
            self = .repairRequired(.inboxConflict(sender: sender, cursor: cursor))
        case .exportCursorMismatch: self = .exportCursorMismatch
        case .exportRevisionChanged: self = .exportRevisionChanged
        case .notArchived: self = .notArchived
        case .confirmationMismatch: self = .confirmationMismatch
        }
    }

    init(_ error: HostEngineError) {
        switch error {
        case .journalUnbound, .generationChanged: self = .fenced
        case .notReady: self = .notReady
        case .archiveLimit: self = .capacity(.retiredJournals)
        case .mlsUnreadable: self = .repairRequired(.mlsUnreadable)
        case .handoffUnproven: self = .repairRequired(.handoffUnproven)
        case .unsettledJoin: self = .unsettledJoin
        case .launchInputsChanged: self = .repairRequired(.launchInputsChanged)
        case .sessionCloseUncertain: self = .repairRequired(.sessionCloseUncertain)
        }
    }
}

// MARK: - Archives

@_spi(HostJournalPreview) public struct HostJournalArchive: Hashable, Sendable {
    public let journalID: Data
    public let group: Data
    public let origin: Data
    public let reason: HostRetirementReason
    public let retainedBytes: UInt64
    public let own: UInt64
    public let remote: UInt64
    public let unapplied: UInt64
    public let pending: UInt64
    public let quarantined: UInt64
    public let heldInbox: UInt64

    init?(_ listing: HostJournalListing) throws {
        guard case .journal(_, let view) = listing, let retirement = view.retirement else { return nil }
        guard view.recordCount >= view.ownHead else {
            throw HostJournalError.repairRequired(.journalCorrupt)
        }
        journalID = view.journalID
        group = view.group
        origin = view.origin
        reason = HostRetirementReason(retirement)
        retainedBytes = view.retainedBytes
        own = view.ownHead
        remote = view.recordCount - view.ownHead
        unapplied = view.undelivered
        pending = view.pendingCount
        quarantined = view.quarantineCount
        heldInbox = view.heldCount
    }
}

@_spi(HostJournalPreview) public enum HostArchiveItem: Sendable {
    case own(record: HostRecordID, mutation: HostMutationID?, envelope: Data, payload: Data)
    case remote(position: JournalPosition, record: HostRecordID, applied: Bool, envelope: Data, payload: Data)
    case pending(record: HostRecordID, envelope: Data)
    case quarantined(sender: Data, cursor: UInt64, reason: HostQuarantineReason, bytes: Data)
    case heldInbox(sender: Data, cursor: UInt64, plaintext: Data)

    /// Exported envelopes were validated when the journal opened; one that
    /// does not parse now is reported as corruption.
    init(_ item: HostJournalExportItem) throws {
        func parsed(_ bytes: Data) throws -> JournalEnvelope {
            do {
                return try JournalEnvelope(parsing: bytes)
            } catch {
                throw HostJournalError.repairRequired(.journalCorrupt)
            }
        }
        switch item {
        case .own(_, let mutationID, let envelope):
            if let mutationID, mutationID.count != 16 {
                throw HostJournalError.repairRequired(.journalCorrupt)
            }
            let record = try parsed(envelope)
            self = .own(
                record: HostRecordID(record.id), mutation: mutationID.map { HostMutationID(bytes: $0) },
                envelope: envelope, payload: record.payload
            )
        case .remote(let position, _, _, let applied, let envelope):
            let record = try parsed(envelope)
            guard let position = JournalPosition(rawValue: position) else { throw HostJournalError.repairRequired(.journalCorrupt) }
            self = .remote(position: position, record: HostRecordID(record.id), applied: applied, envelope: envelope, payload: record.payload)
        case .pending(_, _, let envelope):
            self = .pending(record: HostRecordID(try parsed(envelope).id), envelope: envelope)
        case .quarantined(let sender, let cursor, let reason, let bytes):
            guard let reason = HostQuarantineReason(rawValue: reason) else {
                throw HostJournalError.repairRequired(.journalCorrupt)
            }
            self = .quarantined(sender: sender, cursor: cursor, reason: reason, bytes: bytes)
        case .held(let sender, let cursor, let plaintext):
            self = .heldInbox(sender: sender, cursor: cursor, plaintext: plaintext)
        }
    }
}

@_spi(HostJournalPreview) public enum HostQuarantineReason: String, Sendable {
    case undecodable
    case malformedEnvelopes
}

/// Where the next export page starts. Bound to one journal and one
/// committed revision; a continuation after any commit is refused.
@_spi(HostJournalPreview) public struct HostArchiveCursor: Codable, Hashable, Sendable {
    let value: HostJournalExportCursor

    private enum CodingKeys: String, CodingKey { case version, value }

    init(value: HostJournalExportCursor) {
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "unsupported archive cursor")
        }
        let decoded = try container.decode(HostJournalExportCursor.self, forKey: .value)
        guard Self.isValid(decoded) else {
            throw DecodingError.dataCorruptedError(forKey: .value, in: container, debugDescription: "invalid archive cursor")
        }
        value = decoded
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)
        try container.encode(value, forKey: .value)
    }

    private static func isValid(_ cursor: HostJournalExportCursor) -> Bool {
        guard cursor.journalID.count == 16, cursor.revision <= UInt64(Int64.max) else { return false }
        switch (cursor.section, cursor.key.count) {
        case (0, 1), (1, 1):
            guard case .integer(let position) = cursor.key[0] else { return false }
            return position > 0
        case (2, 2), (3, 2), (4, 2):
            guard case .blob(let identity) = cursor.key[0],
                  case .integer(let position) = cursor.key[1] else { return false }
            return identity.count == (cursor.section == 2 ? 16 : 32)
                && (cursor.section == 2 ? position > 0 : position >= 0)
        default:
            return false
        }
    }
}

@_spi(HostJournalPreview) public struct HostArchivePage: Sendable {
    public let items: [HostArchiveItem]
    public let next: HostArchiveCursor?
}
