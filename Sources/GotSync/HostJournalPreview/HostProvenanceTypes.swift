import Foundation

/// A journal's account of what one store applied in one group. The library
/// issues it with `HostJournal.lineage()`; the host saves the newest one with
/// its provenance and presents every saved token at its next enrollment.
public struct HostLineage: Codable, Hashable, Sendable {
    let record: HostLineageRecord

    init(_ record: HostLineageRecord) {
        self.record = record
    }

    public var group: Data { record.group }
    public var journalID: Data { record.journalID }
    public var applied: [Data: UInt64] { HostVectorEntry.vector(record.applied) }
    public var reclaimedThrough: [Data: UInt64] { HostVectorEntry.vector(record.reclaimedThrough) }

    public init(from decoder: any Decoder) throws {
        let decoded = try HostLineageRecord(from: decoder)
        guard decoded.isWellFormed else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid lineage"))
        }
        record = decoded
    }

    public func encode(to encoder: any Encoder) throws {
        try record.encode(to: encoder)
    }
}

/// The local store a host enrolls, declared once and immutable for the
/// journal. `storeID` is minted by the app once per local store and kept
/// across restores and relinks; the library never mints one.
public struct HostStoreIncarnation: Sendable {
    public enum Content: Sendable {
        case empty
        case nonempty
    }

    public let storeID: UUID
    public let content: Content
    public let lineage: [HostLineage]

    public init(storeID: UUID, content: Content, lineage: [HostLineage]) {
        self.storeID = storeID
        self.content = content
        self.lineage = lineage
    }

    var record: HostStoreIncarnationRecord {
        HostStoreIncarnationRecord(
            storeID: HostMutationID(storeID).bytes, content: content == .empty ? .empty : .nonempty,
            lineage: lineage.map(\.record)
        )
    }
}

/// How the enrolled store's preexisting content relates to this group.
public enum HostAncestry: Equatable, Sendable {
    /// The store was empty.
    case fresh
    /// The store founded this group.
    case founder
    /// A lineage token of this group at or above its reclamation frontier.
    case sameLineage
    /// A lineage token of this group below its reclamation frontier: content
    /// deleted and reclaimed since could resurrect.
    case staleLineage
    /// Nonempty content from other groups only.
    case foreign
    /// Undeclared, or nonempty without lineage.
    case unknown

    init(_ kind: HostAncestryKind) {
        switch kind {
        case .fresh: self = .fresh
        case .founder: self = .founder
        case .sameLineage: self = .sameLineage
        case .staleLineage: self = .staleLineage
        case .foreign: self = .foreign
        case .unknown: self = .unknown
        }
    }
}

/// The host's explicit resolution of an ancestry that does not resolve itself.
public enum HostAncestryResolution: Sendable {
    /// The host merged with preservation: ambiguous old content is kept for
    /// the user, nothing was deleted or re-identified on the library's word.
    case merged
}

/// The store's ancestry and whether it was resolved.
public struct HostAncestryState: Equatable, Sendable {
    public let ancestry: HostAncestry
    public let isResolved: Bool
}

/// Tombstones and clears whose deleting journal record lies at or below
/// `frontier` may be reclaimed. Every store in `stores` agreed.
public struct HostReclamation: Equatable, Sendable {
    public let frontier: [Data: UInt64]
    public let stores: [UUID]
    /// The host reclaimed through the frontier, or installed a checkpoint
    /// that reflects it.
    public let isApplied: Bool

    init(_ state: HostJournalReclamationState) {
        frontier = state.frontier
        stores = state.stores.map { HostMutationID(bytes: $0).uuid }
        isApplied = state.applied
    }
}

/// The finalization fence and the mappings released under it.
public struct HostFinalization: Equatable, Sendable {
    public let capturedThrough: UInt64
    public let ownSequence: UInt64
    public let releasedMappings: UInt64

    init(_ state: HostJournalFinalizationState) {
        capturedThrough = state.capture
        ownSequence = state.own
        releasedMappings = state.released
    }
}
