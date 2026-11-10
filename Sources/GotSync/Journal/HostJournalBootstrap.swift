import CryptoKit
import Foundation

/// Bounds of one snapshot offer. A larger export is refused after Add and
/// the joiner continues on full history.
enum HostSnapshotBounds {
    static let chunkBytes = 8 * 1_048_576
    static let maxChunks = 4
    static let maxBytes = UInt64(chunkBytes * maxChunks)
    static let maxOrigins = 64
    static let maxSchemaBytes = 96
    static let exportAttempts = 3
}

/// Where a recipient's snapshot bootstrap stands. Every phase except
/// `refused`, `installed` and `completed` holds delivery.
enum HostSnapshotPhase: String, Codable, Sendable {
    case requested
    case offered
    case fetching
    case assembled
    case installing
    case installed
    case completed
    case refused

    var holdsDelivery: Bool {
        switch self {
        case .requested, .offered, .fetching, .assembled, .installing: true
        case .installed, .completed, .refused: false
        }
    }
}

/// Why a snapshot was not installed. The raw values travel in `complete`
/// for the provider-side reasons.
enum HostSnapshotRefusalReason: String, Codable, Sendable, CaseIterable {
    case notOffered
    case schemaMismatch
    case notRegistered
    case tooLarge
    case notAtCut
    case exportFailed
    case transferFailed
    case malformedOffer
    case anchorMismatch
    case contentUnavailable
    case contentRejected
    case contentMismatch
    case hostRefused
    case declinedByHost
    case noProvider

    /// Reasons a provider may send; the others arise only at the recipient.
    static let providerReasons: Set<Self> = [.schemaMismatch, .notRegistered, .tooLarge, .notAtCut, .exportFailed, .transferFailed]
}

/// One covered origin: the snapshot reflects exactly its records up to
/// `sequence`, the last of which has `digest`.
struct HostSnapshotAnchor: Codable, Equatable, Hashable, Sendable {
    let origin: Data
    let sequence: UInt64
    let digest: Data
}

/// The bounded manifest of one snapshot, carried in `complete`.
struct HostSnapshotOffer: Codable, Equatable, Sendable {
    let id: Data
    let schema: String
    let anchors: [HostSnapshotAnchor]
    let length: UInt64
    let contentHash: Data
    let chunks: [Data]

    var coverage: [Data: UInt64] {
        Dictionary(uniqueKeysWithValues: anchors.map { ($0.origin, $0.sequence) })
    }

    /// Shape only: identifiers, ordering and bounds. Descriptors are decoded
    /// by the recipient before fetching.
    var isWellFormed: Bool {
        id.count == 16 && HostSnapshotSchemaName.isValid(schema) && contentHash.count == 32
            && (1...HostSnapshotBounds.maxBytes).contains(length)
            && (1...HostSnapshotBounds.maxChunks).contains(chunks.count) && chunks.allSatisfy { !$0.isEmpty && $0.count <= 512 }
            && anchors.count <= HostSnapshotBounds.maxOrigins
            && anchors.allSatisfy { $0.origin.count == 16 && $0.sequence > 0 && $0.digest.count == 32 }
            && zip(anchors, anchors.dropFirst()).allSatisfy { $0.origin.lexicographicallyPrecedes($1.origin) }
    }

    /// The library-owned transfer ID of chunk `index`.
    static func transferID(snapshot id: Data, index: Int) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data("gotsync.snapshot.v1".utf8))
        hasher.update(data: id)
        hasher.update(data: withUnsafeBytes(of: UInt32(index).bigEndian) { Data($0) })
        return Data(hasher.finalize().prefix(16))
    }
}

/// `label/version`, the wire form of a snapshot schema.
enum HostSnapshotSchemaName {
    static func make(label: String, version: UInt16) -> String { "\(label)/\(version)" }

    static func isValid(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard name.utf8.count <= HostSnapshotBounds.maxSchemaBytes, parts.count == 2,
              let version = UInt16(parts[1]), version > 0, String(version) == parts[1]
        else { return false }
        return isLabel(String(parts[0]))
    }

    static func isLabel(_ label: String) -> Bool {
        guard let first = label.unicodeScalars.first, ("a"..."z").contains(first),
              label.utf8.count <= HostSnapshotBounds.maxSchemaBytes - 6
        else { return false }
        return label.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-" }
    }
}

/// The recipient journal's durable bootstrap state.
struct HostJournalBootstrapState: Equatable, Sendable {
    let phase: HostSnapshotPhase
    let schema: String
    let offer: HostSnapshotOffer?
    let refusal: HostSnapshotRefusalReason?
    /// Set at install: the covered records are skipped by delivery.
    let coverage: [Data: UInt64]?
}

/// What a provider export reads in one writer step: the cut and its anchors.
struct HostSnapshotExportCut: Equatable, Sendable {
    let journalID: Data
    let appliedThrough: UInt64
    let capturedThrough: UInt64
    let anchors: [HostSnapshotAnchor]
}
