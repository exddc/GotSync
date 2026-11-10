import Foundation
import GotSyncMLS

/// One decoded application message of the inbox. `control` is a hello or
/// reservation message the engine owns; everything else belongs to the
/// adapter's data intake.
struct ReplicationWindowItem {
    let message: MLSInboxMessage
    let fromSelf: Bool
    let control: ReplicationMessage?
    let decoded: ReplicationDecoded
}

enum ReplicationDecoded {
    case taskOperations([TaskOperation])
    case hostRecords(HostJournalMessage)
    case hostComplete(member: Data, through: ReplicaVersionVector)
    /// A retention proposal, vote or committed-floor corroboration.
    case hostRetention(HostJournalMessage)
    case control
    /// Not readable as a message of this schema.
    case undecodable
}

struct ReplicationChunkIntake {
    /// Leading messages of the chunk whose data is durably owned or was
    /// dropped as invalid, so they may be acknowledged.
    let heldMessages: Int
    let accepted: Int
    /// A hello should follow: operations wait on a gap, or held work resumed.
    let requestsHello: Bool
}

/// The data-specific part of replication: coding, origin inventory and
/// chunking. `SyncEngine` keeps membership, pairing, reservations, reply
/// obligations, checkpoints and acknowledgement. Every member is
/// synchronous. The task demo's intake and selection stay synchronous on
/// `TaskReplicationAdapter`; the host journal's are `HostReplicationData`.
@MainActor
protocol ReplicationData: AnyObject {
    /// Origin of this device's own data, if any exists yet.
    var ownOrigin: ReplicaDeviceID? { get }
    var localSequence: UInt64 { get }
    var helloVector: ReplicaVersionVector { get }
    /// Origins counted against task-history capacity.
    var heldOrigins: [ReplicaDeviceID] { get }
    /// Origins with retained data, for reservation pruning and reply obligations.
    var retainedOrigins: [ReplicaDeviceID] { get }
    var retriesHeldWithoutMessages: Bool { get }

    func encode(_ control: ReplicationMessage) throws -> Data
    func decode(_ plaintext: Data) -> (control: ReplicationMessage?, decoded: ReplicationDecoded)
    /// Origins a not yet drained message commits the group to. Nil when the
    /// message cannot be read, so its origins are unknown.
    func committedOrigins(in decoded: ReplicationDecoded, control: ReplicationMessage?) -> Set<ReplicaDeviceID>?
    /// Index ranges of the window committed one after another.
    func chunks(of window: [ReplicationWindowItem]) -> [Range<Int>]
}

/// The host journal's intake and selection, which read and write the
/// journal file on its writer and so suspend the engine.
@MainActor
protocol HostReplicationData: ReplicationData {
    /// Starts the proof of a whole frozen window; nothing of it is written
    /// before `extendWindowProof` reports it complete.
    func beginWindowProof(_ window: [ReplicationWindowItem]) async throws
    /// One bounded proof step. Returns whether the window is proven.
    func extendWindowProof() async throws -> Bool
    func intake(_ chunk: [ReplicationWindowItem]) async throws -> ReplicationChunkIntake
    /// The next reply message for `obligation` and the records it carries,
    /// none above `bound` when one is given.
    func reply(
        for obligation: ReplyObligation, uploadedThrough: UInt64, bound: ReplicaVersionVector?
    ) async throws -> (plaintext: Data, records: [(ReplicaDeviceID, UInt64)])?
    /// A joiner's hello vector and the data messages announced after it.
    func joinAnnouncement() async throws -> (vector: ReplicaVersionVector, messages: [Data])
    /// The next local batch after `uploadedThrough` and its last sequence.
    func upload(after uploadedThrough: UInt64) async throws -> (plaintext: Data, last: UInt64)
}
