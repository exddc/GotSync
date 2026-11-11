import Foundation

/// One origin's sequence in a stored vector.
struct HostVectorEntry: Codable, Equatable, Hashable, Sendable {
    let origin: Data
    let sequence: UInt64

    static func entries(_ vector: [Data: UInt64]) -> [HostVectorEntry] {
        vector.filter { $0.value > 0 }.sorted { $0.key.lexicographicallyPrecedes($1.key) }
            .map { HostVectorEntry(origin: $0.key, sequence: $0.value) }
    }

    static func vector(_ entries: [HostVectorEntry]) -> [Data: UInt64] {
        Dictionary(entries.map { ($0.origin, $0.sequence) }, uniquingKeysWith: max)
    }

    static func isCanonical(_ entries: [HostVectorEntry]) -> Bool {
        entries.count <= 4_096
            && entries.allSatisfy { $0.origin.count == JournalEnvelope.originLength && (1...JournalEnvelope.maxSequence).contains($0.sequence) }
            && zip(entries, entries.dropFirst()).allSatisfy { $0.origin.lexicographicallyPrecedes($1.origin) }
    }
}

/// A journal's account of what a store applied in one group, issued by the
/// library and kept by the host for its next enrollment.
struct HostLineageRecord: Codable, Equatable, Hashable, Sendable {
    let group: Data
    let journalID: Data
    let storeID: Data?
    let applied: [HostVectorEntry]
    let reclaimedThrough: [HostVectorEntry]

    var isWellFormed: Bool {
        group.count == 32 && journalID.count == 16 && (storeID.map { $0.count == 16 } ?? true)
            && HostVectorEntry.isCanonical(applied) && HostVectorEntry.isCanonical(reclaimedThrough)
    }
}

/// The store a journal's host declared at enrollment; immutable afterwards.
struct HostStoreIncarnationRecord: Codable, Equatable, Sendable {
    enum Content: String, Codable, Sendable {
        case empty
        case nonempty
        case undeclared
    }

    let storeID: Data?
    let content: Content
    let lineage: [HostLineageRecord]

    static let undeclared = HostStoreIncarnationRecord(storeID: nil, content: .undeclared, lineage: [])

    var isWellFormed: Bool {
        (storeID.map { $0.count == 16 } ?? (content == .undeclared)) && lineage.count <= 64 && lineage.allSatisfy(\.isWellFormed)
    }
}

/// How a store's preexisting content relates to this group.
enum HostAncestryKind: String, Codable, Sendable {
    case fresh
    case founder
    case sameLineage
    case staleLineage
    case foreign
    case unknown

    /// Whether this ancestry needs no explicit host resolution.
    var resolvesItself: Bool {
        switch self {
        case .fresh, .founder, .sameLineage: true
        case .staleLineage, .foreign, .unknown: false
        }
    }

    static func classify(
        _ incarnation: HostStoreIncarnationRecord, group: Data, founder: Bool, frontier: [Data: UInt64]?
    ) -> HostAncestryKind {
        switch incarnation.content {
        case .undeclared:
            return founder ? .founder : .unknown
        case .empty:
            return .fresh
        case .nonempty:
            if founder { return .founder }
            let tokens = incarnation.lineage.filter { $0.group == group }
            guard !tokens.isEmpty else { return incarnation.lineage.isEmpty ? .unknown : .foreign }
            let applied = tokens.reduce(into: [Data: UInt64]()) { result, token in
                for entry in token.applied { result[entry.origin] = max(result[entry.origin] ?? 0, entry.sequence) }
            }
            let behind = (frontier ?? [:]).contains { applied[$0.key] ?? 0 < $0.value }
            return behind ? .staleLineage : .sameLineage
        }
    }
}

/// The all-member reclamation frontier: tombstones and clears whose deleting
/// record lies at or below it may be reclaimed by every store in `stores`.
struct HostJournalReclamationState: Equatable, Sendable {
    let frontier: [Data: UInt64]
    let stores: [Data]
    /// The host reclaimed through the frontier, or installed a checkpoint
    /// that already reflects it.
    let applied: Bool

    static func validStores(_ stores: [Data]) -> Bool {
        (1...SyncGroupProfile.supportedMemberCeiling).contains(stores.count) && stores.allSatisfy { $0.count == 16 }
    }

    func isWellFormed(at anchors: [HostSnapshotAnchor]) -> Bool {
        !frontier.isEmpty && HostVectorEntry.isCanonical(HostVectorEntry.entries(frontier))
            && frontier.values.allSatisfy { $0 > 0 }
            && Self.validStores(stores) && HostSnapshotAnchor.isCanonical(anchors)
            && frontier.allSatisfy { origin, sequence in
                anchors.contains { $0.origin == origin && $0.sequence >= sequence }
            }
    }
}

/// The host's finalization fence: no mutation captured at or before
/// `capture` will be submitted again, so mappings of own sequences up to
/// `own` may be released once removed under the floor.
struct HostJournalFinalizationState: Equatable, Sendable {
    let capture: UInt64
    let own: UInt64
    let released: UInt64
}
