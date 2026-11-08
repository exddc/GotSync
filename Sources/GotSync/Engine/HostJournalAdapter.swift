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
}

enum HostLifecycleIntent: String, Codable, Sendable {
    case unlink
    case removed
    case erase
}

enum HostLifecycle: Equatable, Sendable {
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
    let journal: Data?
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

    var unuploaded: UInt64 {
        guard let journal, journal.ownHead > uploadedThrough else { return 0 }
        return journal.ownHead - uploadedThrough
    }

    var isQuiescent: Bool {
        guard let journal else { return false }
        return unuploaded == 0 && journal.undelivered == 0 && journal.pendingCount == 0 && journal.quarantineCount == 0
            && journal.historyApplied && !journal.controlRepair && repair == nil
            && intake == .settled(held: 0) && lifecycle == .active
    }
}

/// Host-journal data for the engine: opaque records in a `HostJournalStore`
/// for the current group generation. Until the first group journal exists
/// the adapter is unbound and holds no data.
@MainActor
final class HostJournalAdapter {
    static let chunkArrivals = 64
    static let chunkEnvelopes = 256
    static let chunkEnvelopeBytes = 262_144
    static let chunkPlaintextBytes = 524_288
    static let replyBytes = 262_144
    static let replyRecords = 256

    let directory: URL
    let limits: HostJournalLimits
    private(set) var store: HostJournalStore?
    /// Revision of the store when the current window's remaining arrivals
    /// were last verified; a different revision verifies them again.
    private var verifiedRevision: UInt64?
    private var verifiedJournal: Data?
    private var unverified: [HostJournalArrival] = []

    init(directory: URL, limits: HostJournalLimits) {
        self.directory = directory
        self.limits = limits
    }

    func bind(_ store: HostJournalStore?) {
        self.store = store
        verifiedRevision = nil
        verifiedJournal = nil
        unverified = []
    }

    private func bound() throws -> HostJournalStore {
        guard let store else { throw HostEngineError.journalUnbound }
        return store
    }

    /// Stores a provider's completion target received from a current member.
    func recordCompletion(provider: Data, through: ReplicaVersionVector) throws {
        let store = try bound()
        try store.recordCompletionTarget(provider: provider, through: Self.dictionary(through))
        if verifiedJournal == store.view.journalID {
            verifiedRevision = store.view.revision
        }
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

    private func message(_ envelopes: [JournalEnvelope]) throws -> (plaintext: Data, records: [(ReplicaDeviceID, UInt64)]) {
        let records = try envelopes.map { (try ReplicaDeviceID(bytes: $0.origin), $0.sequence) }
        return (try HostJournalMessage.records(envelopes.map(\.bytes)).encoded(), records)
    }
}

extension HostJournalAdapter: ReplicationData {
    var ownOrigin: ReplicaDeviceID? {
        store.flatMap { try? ReplicaDeviceID(bytes: $0.view.origin) }
    }

    var localSequence: UInt64 { store?.view.ownHead ?? 0 }

    var helloVector: ReplicaVersionVector {
        Self.vector((try? store?.receivedVector()) ?? [:])
    }

    var heldOrigins: [ReplicaDeviceID] {
        ((try? store?.origins()) ?? []).compactMap { try? ReplicaDeviceID(bytes: $0) }
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

    /// Verifies every data arrival of the window against retained, pending
    /// and incoming records before the first chunk commits.
    func verify(_ window: [ReplicationWindowItem]) throws {
        let arrivals = window.compactMap(Self.arrival)
        guard !arrivals.isEmpty else {
            unverified = []
            return
        }
        let store = try bound()
        try store.verify(arrivals)
        unverified = arrivals
        verifiedJournal = store.view.journalID
        verifiedRevision = store.view.revision
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

    /// Commits the chunk's data arrivals. Messages up to the first arrival
    /// the journal does not own are held; controls before it are owned by
    /// the engine's saves.
    func intake(_ chunk: [ReplicationWindowItem]) throws -> ReplicationChunkIntake {
        let indexes = chunk.indices.filter { Self.arrival(chunk[$0]) != nil }
        guard !indexes.isEmpty else {
            return ReplicationChunkIntake(heldMessages: chunk.count, accepted: 0, requestsHello: false)
        }
        let store = try bound()
        guard verifiedJournal == store.view.journalID, !store.view.isRetired else {
            throw HostEngineError.generationChanged
        }
        if verifiedRevision != store.view.revision {
            try store.verify(unverified)
        }
        let arrivals = indexes.compactMap { Self.arrival(chunk[$0]) }
        let pendingBefore = store.view.pendingCount
        let result = try store.intake(arrivals)
        unverified.removeFirst(min(result.ownedArrivals, unverified.count))
        verifiedRevision = store.view.revision
        let held = result.ownedArrivals < indexes.count ? indexes[result.ownedArrivals] : chunk.count
        return ReplicationChunkIntake(
            heldMessages: held,
            accepted: result.ownedArrivals,
            requestsHello: result.ownedArrivals > 0 && store.view.pendingCount > pendingBefore
        )
    }

    /// Own records missing from the requester and already uploaded, and,
    /// for a provider request, every retained record missing from it,
    /// including own records above the upload watermark.
    func reply(for obligation: ReplyObligation, uploadedThrough: UInt64) throws -> (plaintext: Data, records: [(ReplicaDeviceID, UInt64)])? {
        let store = try bound()
        var selected: [JournalRecordID: JournalEnvelope] = [:]
        if let provided = obligation.provided {
            for envelope in try store.records(
                missingFrom: Self.dictionary(provided), through: nil, maxBytes: Self.replyBytes, maxCount: Self.replyRecords
            ) {
                selected[envelope.id] = envelope
            }
        }
        if let own = obligation.own, let origin = ownOrigin {
            for envelope in try store.ownRecords(after: own[origin], maxBytes: Self.replyBytes, maxCount: Self.replyRecords)
            where envelope.sequence <= uploadedThrough {
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
        return envelopes.isEmpty ? nil : try message(envelopes)
    }

    func joinAnnouncement() throws -> (vector: ReplicaVersionVector, messages: [Data]) {
        let vector = helloVector
        guard let store, store.view.ownHead > 0 else {
            return (vector, [])
        }
        var messages: [Data] = []
        var after: UInt64 = 0
        while after < store.view.ownHead {
            let batch = try store.ownRecords(after: after, maxBytes: Self.replyBytes, maxCount: Self.replyRecords)
            guard let last = batch.last else { break }
            messages.append(try message(batch).plaintext)
            after = last.sequence
        }
        return (vector, messages)
    }

    func upload(after uploadedThrough: UInt64) throws -> (plaintext: Data, last: UInt64) {
        let store = try bound()
        let batch = try store.ownRecords(after: uploadedThrough, maxBytes: Self.replyBytes, maxCount: Self.replyRecords)
        let origin = try ReplicaDeviceID(bytes: store.view.origin)
        guard let last = batch.last, batch.first?.sequence == uploadedThrough + 1 else {
            throw ReplicaError.sequenceGap(origin: origin, expected: uploadedThrough + 1, received: batch.first?.sequence ?? 0)
        }
        return (try message(batch).plaintext, last.sequence)
    }
}

extension ReplicationDecoded {
    var hostRecords: HostJournalMessage? {
        if case .hostRecords(let message) = self { return message }
        return nil
    }
}
