import Foundation

enum HostEngineError: Error, Equatable {
    /// The host profile has no journal for its group yet.
    case journalUnbound
    /// The journal changed generation while a window was being taken.
    case generationChanged
    /// The host has not declared its initial capture submitted.
    case notReady
    /// Four retired or unreadable journals exist.
    case archiveLimit
    /// The MLS state cannot be read; its files are kept for a later retry.
    case mlsUnreadable
    /// No journal of the closing generation can take over the MLS inbox, so
    /// the link is kept as it is.
    case handoffUnproven
    /// An earlier join may still own this session's group; it is adopted
    /// before any new join may replace the session.
    case unsettledJoin
    /// The launch inputs kept changing while it was opening.
    case launchInputsChanged
    /// A session reset could not prove that the old session closed.
    case sessionCloseUncertain
}

enum HostLifecycleIntent: String, Codable, Sendable {
    case unlink
    case removed
    case erase
}

enum HostLifecycle: Equatable, Sendable {
    /// The referenced journal is being validated away from the main actor.
    case opening
    case active
    case closing(HostLifecycleIntent)
    case failed(HostLifecycleIntent)
}

/// A preserving stop found at launch. Nothing is recreated or erased while it lasts.
enum HostRepair: Equatable, Sendable {
    case journalMissing
    case journalUnreadable(String)
    case ambiguousJournal
    case mlsUnreadable
    case lifecycleUnreadable
    /// Opening could not complete; files are kept for a later launch.
    case launchFailed(String)
    /// A session being reset did not prove that it closed. It stays held,
    /// with its files and key, and no new session is built.
    case sessionCloseUncertain
}

/// Inbox messages not owned by the journal after the last settled cycle;
/// unknown while MLS work may have changed the inbox since.
enum HostIntakeSummary: Equatable, Sendable {
    case unknown
    case settled(held: Int)
}

/// The durable closing intent, written before any cleanup starts.
struct HostLifecycleRecord: Codable, Equatable, Sendable {
    let intent: HostLifecycleIntent
    /// The generation whose journal takes over the MLS inbox, and its group.
    let journal: Data?
    let group: Data?
}

/// Committed host state composed from the journal, the checkpoint, the
/// last settled intake and the lifecycle.
struct HostEngineView: Equatable, Sendable {
    let revision: UInt64
    let journal: HostJournalCoreView?
    let uploadedThrough: UInt64
    let intake: HostIntakeSummary
    let lifecycle: HostLifecycle
    let repair: HostRepair?
    /// No accepted journal command is still waiting for its outcome.
    let journalSettled: Bool

    var unuploaded: UInt64 {
        guard let journal, journal.ownHead > uploadedThrough else { return 0 }
        return journal.ownHead - uploadedThrough
    }

    var isQuiescent: Bool {
        guard let journal, journalSettled else { return false }
        return unuploaded == 0 && journal.undelivered == 0 && journal.pendingCount == 0 && journal.quarantineCount == 0
            && journal.historyApplied && !journal.controlRepair && repair == nil
            && intake == .settled(held: 0) && lifecycle == .active
    }
}

/// Host-journal data for the engine: opaque records in a `HostJournal`
/// for the current group generation. Until the first group journal exists
/// the adapter is unbound and holds no data. Shared reads come from the
/// journal's adopted snapshot; everything that reads or writes the file is
/// asynchronous and runs on the journal's writer.
@MainActor
final class HostJournalAdapter {
    static let chunkArrivals = 64
    static let chunkEnvelopes = 256
    static let chunkEnvelopeBytes = 262_144
    static let chunkPlaintextBytes = 524_288
    nonisolated static let replyBytes = 262_144
    nonisolated static let replyRecords = 256

    let directory: URL
    let limits: HostJournalLimits
    private(set) var store: HostJournal?
    /// The writer-held proof of the current window and how many of its
    /// data arrivals were taken.
    private var proof: (id: UUID, consumed: Int)?

    init(directory: URL, limits: HostJournalLimits) {
        self.directory = directory
        self.limits = limits
    }

    func bind(_ store: HostJournal?) {
        self.store = store
        proof = nil
    }

    private func bound() throws -> HostJournal {
        guard let store else { throw HostEngineError.journalUnbound }
        return store
    }

    /// Stores a provider's completion target received from a current member.
    func recordCompletion(provider: Data, through: ReplicaVersionVector) async throws {
        try await bound().recordCompletionTarget(provider: provider, through: Self.dictionary(through))
    }

    static func dictionary(_ vector: ReplicaVersionVector) -> [Data: UInt64] {
        Dictionary(uniqueKeysWithValues: vector.entries.map { ($0.originDeviceID.bytes, $0.sequence) })
    }

    static func vector(_ dictionary: [Data: UInt64]) -> ReplicaVersionVector {
        (try? ReplicaVersionVector(Dictionary(uniqueKeysWithValues: dictionary.compactMap { key, value in
            (try? ReplicaDeviceID(bytes: key)).map { ($0, value) }
        }))) ?? ReplicaVersionVector()
    }

    private static func arrival(_ item: ReplicationWindowItem) -> HostJournalArrival? {
        guard !item.fromSelf else { return nil }
        switch item.decoded {
        case .hostRecords(let message):
            return HostJournalArrival(
                sender: item.message.sender, cursor: item.message.cursor, plaintext: item.message.plaintext, envelopes: message.records
            )
        case .undecodable:
            return HostJournalArrival(
                sender: item.message.sender, cursor: item.message.cursor, plaintext: item.message.plaintext, envelopes: nil
            )
        case .taskOperations, .hostComplete, .control:
            return nil
        }
    }

    /// One records message, encoded on the writer.
    nonisolated private static func message(_ envelopes: [JournalEnvelope]) throws -> HostJournalBatch {
        HostJournalBatch(
            plaintext: try HostJournalMessage.records(envelopes.map(\.bytes)).encoded(),
            records: envelopes.map(\.id)
        )
    }
}

/// An encoded records message and the records it carries.
struct HostJournalBatch: Sendable {
    let plaintext: Data
    let records: [JournalRecordID]
}

extension HostJournalAdapter: ReplicationData {
    var ownOrigin: ReplicaDeviceID? {
        store.flatMap { try? ReplicaDeviceID(bytes: $0.view.origin) }
    }

    var localSequence: UInt64 { store?.view.ownHead ?? 0 }

    var helloVector: ReplicaVersionVector {
        Self.vector(store?.receivedVector ?? [:])
    }

    var heldOrigins: [ReplicaDeviceID] {
        (store?.origins ?? []).compactMap { try? ReplicaDeviceID(bytes: $0) }
    }

    var retainedOrigins: [ReplicaDeviceID] { helloVector.origins }

    var retriesHeldWithoutMessages: Bool { false }

    func encode(_ control: ReplicationMessage) throws -> Data {
        try HostJournalMessage(control: control).encoded()
    }

    func decode(_ plaintext: Data) -> (control: ReplicationMessage?, decoded: ReplicationDecoded) {
        guard let message = try? HostJournalMessage.decode(plaintext) else {
            return (nil, .undecodable)
        }
        switch message.kind {
        case .records:
            return (nil, .hostRecords(message))
        case .complete:
            return (nil, .hostComplete(member: message.member ?? Data(), through: message.through ?? ReplicaVersionVector()))
        case .hello, .reservation, .release, .reservations:
            return (message.control, .control)
        }
    }

    /// Unknown when a message or one of its envelopes cannot be read.
    func committedOrigins(in decoded: ReplicationDecoded, control: ReplicationMessage?) -> Set<ReplicaDeviceID>? {
        switch decoded {
        case .hostRecords(let message):
            var origins: Set<ReplicaDeviceID> = []
            for bytes in message.records ?? [] {
                guard let envelope = try? JournalEnvelope(parsing: bytes), let origin = try? ReplicaDeviceID(bytes: envelope.origin) else {
                    return nil
                }
                origins.insert(origin)
            }
            return origins
        case .control:
            return Set(control?.vector?.origins ?? [])
        case .hostComplete:
            return []
        case .undecodable, .taskOperations:
            return nil
        }
    }

    func chunks(of window: [ReplicationWindowItem]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        var envelopes = 0
        var envelopeBytes = 0
        var plaintextBytes = 0
        for (index, item) in window.enumerated() {
            let records = (item.decoded.hostRecords?.records ?? [])
            let itemBytes = records.reduce(0) { $0 + $1.count }
            let count = index - start
            let exceeds = count + 1 > Self.chunkArrivals || envelopes + records.count > Self.chunkEnvelopes
                || envelopeBytes + itemBytes > Self.chunkEnvelopeBytes
                || plaintextBytes + item.message.plaintext.count > Self.chunkPlaintextBytes
            if exceeds, count > 0 {
                ranges.append(start..<index)
                start = index
                envelopes = 0
                envelopeBytes = 0
                plaintextBytes = 0
            }
            envelopes += records.count
            envelopeBytes += itemBytes
            plaintextBytes += item.message.plaintext.count
        }
        if start < window.count {
            ranges.append(start..<window.count)
        }
        return ranges
    }
}

extension HostJournalAdapter: HostReplicationData {
    /// Starts proving every data arrival of the window against retained,
    /// pending and incoming records; no chunk commits before it is complete.
    func beginWindowProof(_ window: [ReplicationWindowItem]) async throws {
        proof = nil
        let arrivals = window.compactMap(Self.arrival)
        guard !arrivals.isEmpty else { return }
        let store = try bound()
        let id = try await store.beginProof(arrivals)
        guard self.store === store else { throw HostEngineError.generationChanged }
        proof = (id, 0)
    }

    func extendWindowProof() async throws -> Bool {
        guard let current = proof else { return true }
        let store = try bound()
        let complete = try await store.extendProof(current.id)
        guard self.store === store, proof?.id == current.id else { throw HostJournalError.proofStale }
        return complete
    }

    /// Commits the chunk's data arrivals. Messages up to the first arrival
    /// the journal does not own are held; controls before it are owned by
    /// the engine's saves. The writer takes exactly the next arrivals of the
    /// current proof; a result for a replaced proof is refused.
    func intake(_ chunk: [ReplicationWindowItem]) async throws -> ReplicationChunkIntake {
        let indexes = chunk.indices.filter { Self.arrival(chunk[$0]) != nil }
        guard !indexes.isEmpty else {
            return ReplicationChunkIntake(heldMessages: chunk.count, accepted: 0, requestsHello: false)
        }
        let store = try bound()
        guard let current = proof, !store.view.isRetired else {
            throw HostEngineError.generationChanged
        }
        let (result, pendingGrew) = try await store.intake(next: indexes.count, ofProof: current.id, from: current.consumed)
        guard self.store === store, proof?.id == current.id, proof?.consumed == current.consumed else {
            throw HostJournalError.proofStale
        }
        proof = (current.id, current.consumed + result.ownedArrivals)
        let held = result.ownedArrivals < indexes.count ? indexes[result.ownedArrivals] : chunk.count
        return ReplicationChunkIntake(
            heldMessages: held,
            accepted: result.ownedArrivals,
            requestsHello: result.ownedArrivals > 0 && pendingGrew
        )
    }

    /// Own records missing from the requester and already uploaded, and,
    /// for a provider request, every retained record missing from it,
    /// including own records above the upload watermark. Nothing above
    /// `bound` is chosen, so a reply loop ends however many records arrive
    /// or are submitted while it runs. Selected and encoded on the writer.
    func reply(
        for obligation: ReplyObligation, uploadedThrough: UInt64, bound limit: ReplicaVersionVector?
    ) async throws -> (plaintext: Data, records: [(ReplicaDeviceID, UInt64)])? {
        let store = try bound()
        let origin = store.view.origin
        let ceiling = limit.map(Self.dictionary)
        let provided = obligation.provided.map(Self.dictionary)
        let ownAfter = try obligation.own.map { $0[try ReplicaDeviceID(bytes: origin)] }
        let ownLast = min(uploadedThrough, ceiling.map { $0[origin] ?? 0 } ?? uploadedThrough)
        let batch = try await store.read("reply") { journal -> HostJournalBatch? in
            var selected: [JournalRecordID: JournalEnvelope] = [:]
            if let provided {
                for envelope in try journal.records(
                    missingFrom: provided, through: ceiling, maxBytes: Self.replyBytes, maxCount: Self.replyRecords
                ) {
                    selected[envelope.id] = envelope
                }
            }
            if let ownAfter {
                for envelope in try journal.ownRecords(after: ownAfter, maxBytes: Self.replyBytes, maxCount: Self.replyRecords)
                where envelope.sequence <= ownLast {
                    selected[envelope.id] = envelope
                }
            }
            var envelopes: [JournalEnvelope] = []
            var bytes = 0
            for envelope in selected.values.sorted(by: {
                $0.origin == $1.origin ? $0.sequence < $1.sequence : $0.origin.lexicographicallyPrecedes($1.origin)
            }) {
                guard envelopes.count < Self.replyRecords, envelopes.isEmpty || bytes + envelope.bytes.count <= Self.replyBytes else {
                    break
                }
                envelopes.append(envelope)
                bytes += envelope.bytes.count
            }
            return envelopes.isEmpty ? nil : try Self.message(envelopes)
        }
        guard let batch else { return nil }
        return (batch.plaintext, try batch.records.map { (try ReplicaDeviceID(bytes: $0.origin), $0.sequence) })
    }

    /// The hello vector and own head are frozen together from one snapshot
    /// before any batch is read, so records submitted meanwhile cannot
    /// extend the announcement; they are uploaded afterwards.
    func joinAnnouncement() async throws -> (vector: ReplicaVersionVector, messages: [Data]) {
        let vector = helloVector
        guard let store, store.view.ownHead > 0 else {
            return (vector, [])
        }
        let ceiling = store.view.ownHead
        var messages: [Data] = []
        var after: UInt64 = 0
        while after < ceiling {
            let start = after
            let batch = try await store.read("joinAnnouncement") { journal -> (HostJournalBatch, UInt64)? in
                let envelopes = try journal.ownRecords(after: start, maxBytes: Self.replyBytes, maxCount: Self.replyRecords)
                    .filter { $0.sequence <= ceiling }
                guard let last = envelopes.last else { return nil }
                return (try Self.message(envelopes), last.sequence)
            }
            guard self.store === store else { throw HostEngineError.generationChanged }
            guard let (message, last) = batch else { break }
            messages.append(message.plaintext)
            after = last
        }
        return (vector, messages)
    }

    func upload(after uploadedThrough: UInt64) async throws -> (plaintext: Data, last: UInt64) {
        let store = try bound()
        let origin = try ReplicaDeviceID(bytes: store.view.origin)
        let batch = try await store.read("upload") { journal -> (message: HostJournalBatch?, first: UInt64) in
            let envelopes = try journal.ownRecords(after: uploadedThrough, maxBytes: Self.replyBytes, maxCount: Self.replyRecords)
            guard envelopes.first?.sequence == uploadedThrough + 1 else { return (nil, envelopes.first?.sequence ?? 0) }
            return (try Self.message(envelopes), uploadedThrough + 1)
        }
        guard let message = batch.message, let last = message.records.last else {
            throw ReplicaError.sequenceGap(origin: origin, expected: uploadedThrough + 1, received: batch.first)
        }
        return (message.plaintext, last.sequence)
    }
}

extension ReplicationDecoded {
    var hostRecords: HostJournalMessage? {
        if case .hostRecords(let message) = self { return message }
        return nil
    }
}
