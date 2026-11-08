import Foundation

/// The task demo's replicated data: the replica, remote operations held on
/// disk because they exceed a replica limit, and the choice of which task
/// operations to apply, answer, announce, and upload.
///
/// `SyncEngine` keeps membership, pairing, transport, the checkpoint, reply
/// obligations, and inbox acknowledgement. Every call here is synchronous,
/// so the engine's suspension points stay where they are.
@MainActor
final class TaskReplicationAdapter {
    private(set) var replica: TaskReplica
    /// Valid remote operations kept on disk because applying them would
    /// exceed a replica limit.
    private(set) var deferredOperations: [TaskOperation] = [] { didSet { deferredOperationsChanged?() } }
    var deferredOperationsChanged: (@MainActor () -> Void)?
    private let deferredOperationsURL: URL
    private let deferredOperationLimit: Int
    private var retriesDeferredWithoutMessages = true

    init(replica: TaskReplica, deferredOperationsURL: URL, deferredOperationLimit: Int) {
        self.replica = replica
        self.deferredOperationsURL = deferredOperationsURL
        self.deferredOperationLimit = deferredOperationLimit
    }

    var tasks: [ReplicatedTask] { replica.tasks }
    var isEmpty: Bool { replica.isEmpty }
    var localOrigin: ReplicaDeviceID { replica.localOrigin }
    var versionVector: ReplicaVersionVector { replica.versionVector }
    var localSequence: UInt64 { replica.versionVector[replica.localOrigin] }
    var hasDeferredOperations: Bool { !deferredOperations.isEmpty }

    /// Whether a drain with an empty inbox should still retry deferred
    /// operations. Cleared by the first intake.
    var retriesDeferredOperationsWithoutMessages: Bool {
        retriesDeferredWithoutMessages && !deferredOperations.isEmpty
    }

    // MARK: - Origins

    /// Origins of applied operations and of saved operations that exceed a
    /// replica limit.
    var heldOrigins: [ReplicaDeviceID] {
        Set(replica.versionVector.origins).union(deferredOperations.map(\.originDeviceID)).sorted()
    }

    /// Origins this replica holds operations from.
    var retainedOrigins: [ReplicaDeviceID] { replica.versionVector.origins }

    /// Origins a delivered message commits the group to: those of its
    /// operations and of its hello vector.
    static func committedOrigins(in message: ReplicationMessage) -> Set<ReplicaDeviceID> {
        Set(message.operations?.map(\.originDeviceID) ?? []).union(message.vector?.origins ?? [])
    }

    // MARK: - Local edits

    func task(id: UUID) -> ReplicatedTask? {
        replica.task(id: id)
    }

    func createTask(title: String) throws {
        try replica.createTask(title: title)
    }

    func setCompleted(taskID: UUID, completed: Bool) throws {
        try replica.setCompleted(taskID: taskID, completed: completed)
    }

    func deleteTask(taskID: UUID) throws {
        try replica.deleteTask(taskID: taskID)
    }

    // MARK: - Remote intake

    struct Intake {
        let accepted: Int
        /// Earlier deferred operations applied.
        let resumedDeferred: Bool
        /// Leading arrivals whose operations are now applied, saved, or
        /// dropped as invalid. Only those may be acknowledged.
        let heldArrivals: Int
        /// Operations still waiting on a gap; they are neither applied nor
        /// saved.
        let waiting: [TaskOperation]
    }

    /// Checks every arrival against retained, deferred, and other incoming
    /// operations, then applies every operation whose origin sequence is next.
    /// Operations over a replica limit are saved while they fit within the
    /// deferred limit; the arrivals after the first one that does not fit are
    /// not held and must stay unacknowledged in the inbox.
    func intake(_ arrivals: [[TaskOperation]]) throws -> Intake {
        typealias ID = TaskReplica.OperationID
        let pool = arrivals.flatMap { $0 }
        if let forked = try replica.forkedOperation(in: pool) {
            throw ReplicaError.operationFork(origin: forked.originDeviceID, sequence: forked.originSequence)
        }
        let previous = deferredOperations
        let intake = try replica.applyAvailable(pool, previouslyDeferred: previous)
        retriesDeferredWithoutMessages = false
        let blocked = Set(intake.deferred.map(ID.init))
        let waiting = Set(intake.waiting.map(ID.init))
        var saved = Set(previous.map(ID.init)).intersection(blocked.union(waiting))
        var heldArrivals = 0
        for operations in arrivals {
            let added = Set(operations.map(ID.init)).intersection(blocked).subtracting(saved)
            guard added.isEmpty || saved.count + added.count <= deferredOperationLimit else {
                break
            }
            saved.formUnion(added)
            heldArrivals += 1
        }
        let deferred = (intake.deferred + intake.waiting)
            .filter { saved.contains(ID($0)) }
            .sorted(by: ReplicaOrdering.operations)
        if deferred != previous {
            try DeferredOperationStore.save(deferred, to: deferredOperationsURL)
            deferredOperations = deferred
        }
        let vector = replica.versionVector
        return Intake(
            accepted: intake.accepted,
            resumedDeferred: previous.contains { $0.originSequence <= vector[$0.originDeviceID] },
            heldArrivals: heldArrivals,
            waiting: intake.waiting
        )
    }

    // MARK: - Outgoing selection

    /// What saved hellos ask for: this device's uploaded operations missing
    /// from `own`, and every operation missing from `provided` except local
    /// ones not yet uploaded.
    func replyOperations(for obligation: ReplyObligation, uploadedThrough: UInt64) -> [TaskOperation] {
        var answer: [TaskReplica.OperationID: TaskOperation] = [:]
        if let own = obligation.own {
            for operation in replica.operations(missingFrom: own)
            where operation.originDeviceID == replica.localOrigin && operation.originSequence <= uploadedThrough {
                answer[TaskReplica.OperationID(operation)] = operation
            }
        }
        if let provided = obligation.provided {
            for operation in replica.operations(missingFrom: provided)
            where operation.originDeviceID != replica.localOrigin || operation.originSequence <= uploadedThrough {
                answer[TaskReplica.OperationID(operation)] = operation
            }
        }
        return answer.values.sorted(by: ReplicaOrdering.operations)
    }

    /// A joiner's announcement: its vector and every operation it retains.
    var announcement: (vector: ReplicaVersionVector, operations: [TaskOperation]) {
        (replica.versionVector, replica.retainedOperations)
    }

    /// The next batch of local operations after `uploadedThrough`, which
    /// must continue it without a gap.
    func uploadBatch(after uploadedThrough: UInt64) throws -> (operations: [TaskOperation], last: TaskOperation) {
        let pending = replica.retainedOperations.filter {
            $0.originDeviceID == replica.localOrigin && $0.originSequence > uploadedThrough
        }
        guard pending.first?.originSequence == uploadedThrough + 1,
              let batch = try OperationBatcher.batches(pending).first,
              let last = batch.last
        else {
            throw ReplicaError.sequenceGap(
                origin: replica.localOrigin,
                expected: uploadedThrough + 1,
                received: pending.first?.originSequence ?? 0
            )
        }
        return (batch, last)
    }

    // MARK: - Held state

    /// Fails when the deferred file exists but cannot be read.
    func loadDeferredOperations() throws {
        deferredOperations = try DeferredOperationStore.load(from: deferredOperationsURL)
    }

    func removeDeferredOperationsFile() throws {
        try DeferredOperationStore.remove(at: deferredOperationsURL)
    }

    func forgetDeferredOperations() {
        deferredOperations = []
    }

    func replaceReplica(_ replica: TaskReplica) {
        self.replica = replica
    }
}

extension TaskReplicationAdapter: ReplicationData {
    var ownOrigin: ReplicaDeviceID? { localOrigin }
    var helloVector: ReplicaVersionVector { versionVector }
    var retriesHeldWithoutMessages: Bool { retriesDeferredOperationsWithoutMessages }

    func encode(_ control: ReplicationMessage) throws -> Data {
        try control.encoded()
    }

    func decode(_ plaintext: Data) -> (control: ReplicationMessage?, decoded: ReplicationDecoded) {
        guard let message = try? ReplicationMessage.decode(plaintext) else {
            return (nil, .undecodable)
        }
        if message.kind == .operations {
            return (nil, .taskOperations(message.operations ?? []))
        }
        return (message, .control)
    }

    /// The demo skips messages it cannot decode, as it always has.
    func committedOrigins(in decoded: ReplicationDecoded, control: ReplicationMessage?) -> Set<ReplicaDeviceID>? {
        if case .taskOperations(let operations) = decoded {
            return Set(operations.map(\.originDeviceID))
        }
        return Set(control?.vector?.origins ?? [])
    }

    func verify(_ window: [ReplicationWindowItem]) throws {}

    func chunks(of window: [ReplicationWindowItem]) -> [Range<Int>] {
        [window.indices]
    }

    func intake(_ chunk: [ReplicationWindowItem]) throws -> ReplicationChunkIntake {
        let arrivals = chunk.map { item -> [TaskOperation] in
            guard !item.fromSelf, case .taskOperations(let operations) = item.decoded else { return [] }
            return operations
        }
        let result = try intake(arrivals)
        return ReplicationChunkIntake(
            heldMessages: result.heldArrivals,
            accepted: result.accepted,
            requestsHello: (!result.waiting.isEmpty && result.heldArrivals > 0) || result.resumedDeferred
        )
    }

    func reply(
        for obligation: ReplyObligation, uploadedThrough: UInt64, bound: ReplicaVersionVector?
    ) throws -> (plaintext: Data, records: [(ReplicaDeviceID, UInt64)])? {
        guard let batch = try OperationBatcher.batches(replyOperations(for: obligation, uploadedThrough: uploadedThrough)).first else {
            return nil
        }
        return (try ReplicationMessage.operations(batch).encoded(), batch.map { ($0.originDeviceID, $0.originSequence) })
    }

    func joinAnnouncement() throws -> (vector: ReplicaVersionVector, messages: [Data]) {
        let (vector, operations) = announcement
        return (vector, try OperationBatcher.batches(operations).map { try ReplicationMessage.operations($0).encoded() })
    }

    func upload(after uploadedThrough: UInt64) throws -> (plaintext: Data, last: UInt64) {
        let (batch, last) = try uploadBatch(after: uploadedThrough)
        return (try ReplicationMessage.operations(batch).encoded(), last.originSequence)
    }
}
