import Foundation

/// What a member's host attests before its library accepts a retention
/// floor: the durable cut its store is at.
public struct HostRetentionRequest: Sendable {
    public let journalID: Data
    public let appliedThrough: JournalPosition?
    public let capturedThrough: UInt64
    /// The proposed floor: the highest sequence per origin that would be removed.
    public let floor: [Data: UInt64]
}

/// The host's answer, read from its own durable state.
public struct HostRetentionAttestation: Sendable {
    /// The application marker saved in the host's store.
    public let appliedThrough: JournalPosition?
    /// The capture counter saved with the host's outbox.
    public let capturedThrough: UInt64
    /// No captured mutation waits to be submitted.
    public let outboxEmpty: Bool
    /// The host's compact state keeps every deletion and clear barrier, so
    /// removing records never resurrects deleted content.
    public let keepsDeletionMetadata: Bool

    public init(appliedThrough: JournalPosition?, capturedThrough: UInt64, outboxEmpty: Bool, keepsDeletionMetadata: Bool) {
        self.appliedThrough = appliedThrough
        self.capturedThrough = capturedThrough
        self.outboxEmpty = outboxEmpty
        self.keepsDeletionMetadata = keepsDeletionMetadata
    }
}

/// The app's retention host. Without it this member always declines, so
/// no floor advances in its group.
public struct HostRetentionHooks: Sendable {
    public let attest: @Sendable (HostRetentionRequest) async throws -> HostRetentionAttestation
    /// In reclaiming groups: delete tombstones and clears whose deleting
    /// journal record lies at or below the frontier and save the frontier in
    /// the same transaction. Asked again until it returns; must be
    /// idempotent. Without it this member declines reclamation.
    public let reclaim: (@Sendable (HostReclamation) async throws -> Void)?

    public init(
        attest: @escaping @Sendable (HostRetentionRequest) async throws -> HostRetentionAttestation,
        reclaim: (@Sendable (HostReclamation) async throws -> Void)? = nil
    ) {
        self.attest = attest
        self.reclaim = reclaim
    }
}

/// Why a member declined a proposed floor.
public enum HostRetentionDecline: Equatable, Sendable {
    case unsupported
    case notCurrent
    case notCaughtUp
    case anchorMismatch
    case belowCommittedFloor
    case unsettled
    case hostNotAtCut
    case checkpointUnavailable
    case checkpointMismatch
    case ancestryUnresolved

    init(_ reason: HostRetentionDeclineReason) {
        switch reason {
        case .unsupported: self = .unsupported
        case .notCurrent: self = .notCurrent
        case .notCaughtUp: self = .notCaughtUp
        case .anchorMismatch: self = .anchorMismatch
        case .belowCommittedFloor: self = .belowCommittedFloor
        case .unsettled: self = .unsettled
        case .hostNotAtCut: self = .hostNotAtCut
        case .checkpointUnavailable: self = .checkpointUnavailable
        case .checkpointMismatch: self = .checkpointMismatch
        case .ancestryUnresolved: self = .ancestryUnresolved
        }
    }
}

public enum HostRetentionProposalOutcome: Equatable, Sendable {
    /// A round started; it commits only when every current member accepts.
    case proposed
    /// Another member coordinates rounds for the current roster.
    case notCoordinator
    /// The group's profile does not allow compaction.
    case notCompacting
    /// A round is already open.
    case roundOpen
    /// This member cannot propose now.
    case declined(HostRetentionDecline)
}

/// A committed retention floor and what was removed under it.
public struct HostRetentionState: Equatable, Sendable {
    /// The highest removable sequence per origin.
    public let floor: [Data: UInt64]
    public let prunedRecords: UInt64
    public let prunedBytes: UInt64
    /// The floor's records are reflected in this host's state; false for a
    /// joiner that adopted the floor but has not installed its checkpoint.
    public let floorApplied: Bool

    init(_ state: HostJournalRetentionState) {
        floor = state.floor
        prunedRecords = state.prunedRecords
        prunedBytes = state.prunedBytes
        floorApplied = state.floorApplied
    }
}
