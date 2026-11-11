import CryptoKit
import Foundation

/// Bounds of retention rounds and pruning.
enum HostRetentionBounds {
    /// Records removed per pruning transaction.
    static let pruneStep = 512
    /// Retained bytes from which the coordinator proposes on its own.
    static let automaticBytes: UInt64 = 16 * 1_048_576
    /// Checkpoint artifact generations kept per journal: the committed one
    /// and one candidate.
    static let artifactGenerations = 2
    /// An open round that has not committed by then is dropped.
    static let roundTimeout: Duration = .seconds(600)
}

/// A committed all-member retention floor. Records at or below `anchors`
/// may be removed; the checkpoint reflects exactly them.
struct HostJournalRetentionState: Equatable, Sendable {
    let round: Data
    /// SHA-256 of the canonical proposal every member accepted.
    let proposal: Data
    let anchors: [HostSnapshotAnchor]
    let checkpoint: HostSnapshotOffer
    /// The floor's records are reflected in the host's state: true for a
    /// member that applied them, and for a joiner once it installed the
    /// checkpoint.
    let floorApplied: Bool
    let prunedRecords: UInt64
    let prunedBytes: UInt64
    /// Pruned records that had positions; positions are never reused.
    let prunedPositions: UInt64

    var floor: [Data: UInt64] { Dictionary(uniqueKeysWithValues: anchors.map { ($0.origin, $0.sequence) }) }

    func anchor(_ origin: Data) -> HostSnapshotAnchor? { anchors.first { $0.origin == origin } }
}

/// Why a member does not accept a proposed floor.
enum HostRetentionDeclineReason: String, Codable, Sendable, CaseIterable {
    case unsupported
    case notCurrent
    case notCaughtUp
    case anchorMismatch
    case belowCommittedFloor
    case unsettled
    case hostNotAtCut
    case checkpointUnavailable
    case checkpointMismatch
    /// The store's ancestry still needs the host's explicit resolution.
    case ancestryUnresolved
}

/// One round's proposal, as broadcast by the coordinator.
struct HostRetentionProposal: Codable, Equatable, Sendable {
    let round: Data
    let epoch: UInt64
    let roster: [Data]
    let anchors: [HostSnapshotAnchor]
    let checkpoint: HostSnapshotOffer
    /// Reclaiming groups: the anchors are also the reclamation frontier.
    var reclaim: Bool? = nil
    /// The coordinator's declared store, required for reclamation.
    var store: Data? = nil

    var digest: Data { Data(SHA256.hash(data: (try? ReplicaCanonicalJSON.encode(self)) ?? Data())) }

    var isWellFormed: Bool {
        round.count == 16 && !roster.isEmpty && roster.count <= SyncGroupProfile.supportedMemberCeiling
            && roster.allSatisfy { $0.count == 32 } && zip(roster, roster.dropFirst()).allSatisfy { $0.lexicographicallyPrecedes($1) }
            && !anchors.isEmpty && checkpoint.isWellFormed && checkpoint.anchors == anchors && checkpoint.floor == nil
            && (reclaim != true || store?.count == 16)
    }
}

/// A member's answer to one proposal, attributed to its authenticated sender.
struct HostRetentionVote: Codable, Equatable, Sendable {
    let round: Data
    let proposal: Data
    let accept: Bool
    var reason: HostRetentionDeclineReason?
    var applied: [HostSnapshotAnchor]?
    /// The voter's declared store, for a reclamation round's scope.
    var store: Data? = nil

    var isWellFormed: Bool {
        round.count == 16 && proposal.count == 32 && accept == (reason == nil)
            && (applied?.count ?? 0) <= HostSnapshotBounds.maxOrigins
    }
}

/// A member's committed floor, sent to a joiner that asked for a snapshot.
struct HostRetentionCorroboration: Codable, Equatable, Sendable {
    let member: Data
    let round: Data
    let proposal: Data
    let anchors: [HostSnapshotAnchor]
    let contentHash: Data
    /// The group's reclamation frontier and scope, when it reclaimed.
    var reclaimedThrough: [HostVectorEntry]? = nil
    var stores: [Data]? = nil

    var isWellFormed: Bool {
        member.count == 32 && round.count == 16 && proposal.count == 32 && contentHash.count == 32 && !anchors.isEmpty
            && anchors.count <= HostSnapshotBounds.maxOrigins
    }
}
