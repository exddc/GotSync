import Foundation

/// Plaintext of one MLS application message.
///
/// `operations` carries task operations from any origin. `hello` reports the
/// sender's version vector so other members can send what it lacks. A joiner
/// names its inviter as `provider`, which answers with every missing origin.
///
/// `reservation` claims task-history slots for a joiner before its Add, and
/// `release` withdraws the sender's own claim at log position `reservation`
/// when its Add never happened. `reservations` answers the hello of the new
/// member `member` with the claims it could not read before it joined.
struct ReplicationMessage: Codable, Equatable, Sendable {
    static let version = 2

    enum Kind: String, Codable, Sendable {
        case operations
        case hello
        case reservation
        case release
        case reservations
    }

    let version: Int
    let kind: Kind
    let operations: [TaskOperation]?
    let vector: ReplicaVersionVector?
    let provider: Data?
    var member: Data? = nil
    var origins: [ReplicaDeviceID]? = nil
    var epoch: UInt64? = nil
    var reservation: UInt64? = nil
    var reservations: [OriginReservation]? = nil
    var overflowed: Bool? = nil

    static func operations(_ operations: [TaskOperation]) -> ReplicationMessage {
        ReplicationMessage(version: version, kind: .operations, operations: operations, vector: nil, provider: nil)
    }

    static func hello(vector: ReplicaVersionVector, provider: Data?) -> ReplicationMessage {
        ReplicationMessage(version: version, kind: .hello, operations: nil, vector: vector, provider: provider)
    }

    static func reservation(member: Data, origins: [ReplicaDeviceID], epoch: UInt64) -> ReplicationMessage {
        ReplicationMessage(
            version: version, kind: .reservation, operations: nil, vector: nil, provider: nil,
            member: member, origins: origins.sorted(), epoch: epoch
        )
    }

    static func release(member: Data, reservation: UInt64) -> ReplicationMessage {
        ReplicationMessage(
            version: version, kind: .release, operations: nil, vector: nil, provider: nil,
            member: member, reservation: reservation
        )
    }

    static func reservations(_ entries: [OriginReservation], overflowed: Bool, for member: Data) -> ReplicationMessage {
        ReplicationMessage(
            version: version, kind: .reservations, operations: nil, vector: nil, provider: nil,
            member: member, reservations: entries, overflowed: overflowed ? true : nil
        )
    }

    func encoded() throws -> Data {
        let data = try ReplicaCanonicalJSON.encode(self)
        guard data.count <= ProtocolLimits.plaintextBytes else { throw WireMessageError.messageTooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> ReplicationMessage {
        guard data.count <= ProtocolLimits.plaintextBytes else { throw WireMessageError.messageTooLarge }
        let message = try ReplicaCanonicalJSON.decode(ReplicationMessage.self, from: data)
        guard message.version == version else { throw WireMessageError.invalidVersion }
        let hasReservationFields = message.member != nil || message.origins != nil
            || message.epoch != nil || message.reservation != nil || message.reservations != nil
            || message.overflowed != nil
        switch message.kind {
        case .operations:
            guard
                let operations = message.operations,
                !operations.isEmpty,
                operations.count <= ReplicaLimits.maxBatchOperations,
                message.vector == nil,
                message.provider == nil,
                !hasReservationFields
            else {
                throw WireMessageError.invalidMessage
            }
        case .hello:
            guard
                message.operations == nil,
                message.vector != nil,
                message.provider.map({ $0.count == 32 }) ?? true,
                !hasReservationFields
            else {
                throw WireMessageError.invalidMessage
            }
        case .reservation:
            guard
                message.operations == nil, message.vector == nil, message.provider == nil,
                message.member?.count == 32,
                let origins = message.origins, OriginReservation.isCanonical(origins),
                message.epoch != nil, message.reservation == nil, message.reservations == nil,
                message.overflowed == nil
            else {
                throw WireMessageError.invalidMessage
            }
        case .release:
            guard
                message.operations == nil, message.vector == nil, message.provider == nil,
                message.member?.count == 32, message.reservation != nil,
                message.origins == nil, message.epoch == nil, message.reservations == nil,
                message.overflowed == nil
            else {
                throw WireMessageError.invalidMessage
            }
        case .reservations:
            guard
                message.operations == nil, message.vector == nil, message.provider == nil,
                message.member?.count == 32, message.origins == nil, message.epoch == nil,
                message.reservation == nil,
                let entries = message.reservations,
                entries.count <= OriginReservation.maximumStored,
                message.overflowed ?? true,
                entries.allSatisfy({
                    $0.member.count == 32 && $0.owner.count == 32 && OriginReservation.isCanonical($0.origins)
                })
            else {
                throw WireMessageError.invalidMessage
            }
        }
        return message
    }
}

/// A claim on task-history slots that `owner` made for `member` before adding
/// it. `cursor` is the relay log position of the claim, so every member
/// orders claims the same way.
///
/// The claim is a lease measured in MLS epochs, not wall-clock time: the
/// owner adds `member` only while the group epoch is below
/// `epoch + leaseEpochs`. An Add commit applies only at the epoch it was
/// prepared for, so a member that has processed that many epochs without
/// seeing `member` join knows the Add can no longer happen.
struct OriginReservation: Codable, Equatable, Sendable {
    /// Admission fails closed once this many claims are active.
    static let maximumActive = 16
    /// A checkpoint stores at most this many claims; past it, admission fails
    /// closed for the rest of the link.
    static let maximumStored = 64
    static let leaseEpochs: UInt64 = 8

    let member: Data
    let owner: Data
    let origins: [ReplicaDeviceID]
    let epoch: UInt64
    let cursor: UInt64
    var released = false
    var admitted = false

    static func isCanonical(_ origins: [ReplicaDeviceID]) -> Bool {
        origins.count <= ReplicaLimits.maxOrigins && zip(origins, origins.dropFirst()).allSatisfy { $0 < $1 }
    }

    func allowsAdd(atEpoch current: UInt64) -> Bool {
        current < epoch &+ Self.leaseEpochs
    }

    /// A claim for a current member counts until the member leaves; neither
    /// the lease nor a release frees slots for a device already added.
    func isActive(roster: Set<Data>, epoch current: UInt64) -> Bool {
        roster.contains(member) || (!released && !admitted && allowsAdd(atEpoch: current))
    }

    /// A claim this member sent without learning where it landed. `after` is
    /// the log cursor this member had reached before sending it.
    struct Attempt: Codable, Equatable, Sendable {
        let member: Data
        let origins: [ReplicaDeviceID]
        let epoch: UInt64
        let after: UInt64

        var message: ReplicationMessage { .reservation(member: member, origins: origins, epoch: epoch) }
    }
}

/// Engine state for the current MLS group that MLS itself does not hold.
struct ReplicationCheckpoint: Codable, Equatable, Sendable {
    static let filename = "sync-v2.json"
    static let joinIntentFilename = "sync-v2-join.json"
    /// Claims a founding inviter makes before its checkpoint exists.
    static let foundingClaimsFilename = "sync-v2-claims.json"
    static let unreadableFoundingClaimsFilename = "sync-v2-claims-unreadable.json"
    static let version = 2

    struct Member: Codable, Equatable, Sendable {
        let deviceID: Data
        let fingerprint: Data
    }

    /// A member this device added that has not yet sent a message. It is
    /// removed once `deadline` passes.
    struct ProvisionalMember: Codable, Equatable, Sendable {
        let fingerprint: Data
        let deadline: Date
    }

    var version = Self.version
    let group: Data
    var uploadedThrough: UInt64
    /// The local origin that `uploadedThrough` counts. Checkpoints written
    /// before replicas had their own origin omit it and count the device ID.
    var uploadOrigin: ReplicaDeviceID?
    var members: [Member]
    var joinPending: Bool
    var provider: Data?
    var pendingRemovals: [Data] = []
    var provisionalMembers: [ProvisionalMember] = []
    /// Absent means no claims.
    var originReservations: [OriginReservation]? = nil
    /// `false` for a new member until its inviter answers its hello with the
    /// reservations made before it joined. `nil` counts as `true`.
    var reservationsVisible: Bool? = nil
    var reservationsProvider: Data? = nil
    var reservationsOverflowed: Bool? = nil
    var reservationAttempts: [OriginReservation.Attempt]? = nil
    /// Members added while the founding claims file could not be read. Their
    /// history counts as unknown until each sends a hello.
    var membersWithUnknownHistory: [Data]? = nil
    /// The host journal generation this link belongs to; absent for task groups.
    var hostJournal: Data? = nil

    var memberDeviceIDs: [Data] { members.map(\.deviceID) }

    func uploadedThrough(origin: ReplicaDeviceID, deviceID: ReplicaDeviceID) -> UInt64 {
        (uploadOrigin ?? deviceID) == origin ? uploadedThrough : 0
    }

    mutating func setUploadedThrough(_ sequence: UInt64, origin: ReplicaDeviceID) {
        uploadedThrough = sequence
        uploadOrigin = origin
    }

    init(group: Data, members: [Member], joinPending: Bool, provider: Data?) {
        self.group = group
        uploadedThrough = 0
        self.members = members
        self.joinPending = joinPending
        self.provider = provider
    }

    static func load(from url: URL) throws -> ReplicationCheckpoint? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let checkpoint = try ReplicaCanonicalJSON.decode(ReplicationCheckpoint.self, from: Data(contentsOf: url))
        guard checkpoint.version == version, checkpoint.group.count == 32 else {
            throw SyncError.invalidCredentials
        }
        return checkpoint
    }

    func save(to url: URL) throws {
        try ProtectedStorage.write(ReplicaCanonicalJSON.encode(self), to: url)
    }

    static func remove(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// Remote operations that are valid but exceed a replica limit. They are saved
/// before the inbox messages that carried them are acknowledged.
enum DeferredOperationStore {
    static let filename = "replica-v1.deferred.json"
    static let version = 1
    static let maximumCount = ReplicaLimits.maxOperations

    private struct Stored: Codable {
        let version: Int
        let operations: [TaskOperation]
    }

    static func load(from url: URL) throws -> [TaskOperation] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let stored = try ReplicaCanonicalJSON.decode(Stored.self, from: Data(contentsOf: url))
        guard stored.version == version else {
            throw ReplicaError.corruptArchive("The deferred operations are unreadable.")
        }
        return stored.operations
    }

    static func save(_ operations: [TaskOperation], to url: URL) throws {
        guard !operations.isEmpty else {
            try remove(at: url)
            return
        }
        try ProtectedStorage.write(
            ReplicaCanonicalJSON.encode(Stored(version: version, operations: operations)),
            to: url
        )
    }

    static func remove(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// Hellos this device acknowledged before answering them in full. Answers are
/// sent from here after the log is caught up, one batch at a time, and resume
/// after a failed send or a restart.
struct ReplyObligation: Codable, Equatable, Sendable {
    static let filename = "sync-v2-replies.json"
    static let version = 1

    var version = Self.version
    /// Lowest vector among hellos that ask for this device's own operations.
    var own: ReplicaVersionVector?
    /// Lowest vector among hellos that name this device as provider, which
    /// asks for every origin.
    var provided: ReplicaVersionVector?
    /// Members whose hello named this device as provider and that still wait
    /// for a reservations snapshot, in the order they asked.
    var recipients: [Data]?
    /// Host-journal members waiting for a completion message; absent for task groups.
    var bootstrap: [Bootstrap]? = nil

    /// A member's history request. `cut` is chosen once this provider may
    /// certify its history and never changes afterwards.
    struct Bootstrap: Codable, Equatable, Sendable {
        let member: Data
        let from: ReplicaVersionVector
        var cut: ReplicaVersionVector?
    }

    var isEmpty: Bool { own == nil && provided == nil && (recipients ?? []).isEmpty && (bootstrap ?? []).isEmpty }

    /// Adds a request unless `member` already has one; a repeated hello does
    /// not replace its cut.
    mutating func addBootstrap(_ member: Data, from vector: ReplicaVersionVector) {
        var entries = bootstrap ?? []
        guard !entries.contains(where: { $0.member == member }) else { return }
        entries.append(Bootstrap(member: member, from: vector, cut: nil))
        bootstrap = Array(entries.suffix(SyncGroupProfile.supportedMemberCeiling))
    }

    mutating func removeBootstrap(_ member: Data) {
        bootstrap?.removeAll { $0.member == member }
        if bootstrap?.isEmpty == true {
            bootstrap = nil
        }
    }

    mutating func addRecipient(_ member: Data) {
        var members = recipients ?? []
        if !members.contains(member) {
            members.append(member)
        }
        recipients = Array(members.suffix(SyncGroupProfile.supportedMemberCeiling))
    }

    mutating func removeRecipient(_ member: Data) {
        recipients?.removeAll { $0 == member }
        if recipients?.isEmpty == true {
            recipients = nil
        }
    }

    mutating func completeHistory() {
        own = nil
        provided = nil
    }

    mutating func merge(_ vector: ReplicaVersionVector, provider: Bool) {
        if provider {
            provided = Self.lower(provided, vector)
        } else {
            own = Self.lower(own, vector)
        }
    }

    /// Records that `operations`, a prefix of the answer in replica order,
    /// was delivered.
    mutating func advance(past operations: [TaskOperation]) {
        for operation in operations {
            own?.raise(operation)
            provided?.raise(operation)
        }
    }

    /// Records that these records, a prefix of the answer in origin and
    /// sequence order, were delivered.
    mutating func advance(past records: [(origin: ReplicaDeviceID, sequence: UInt64)]) {
        for record in records {
            own?.raise(record.origin, to: record.sequence)
            provided?.raise(record.origin, to: record.sequence)
        }
    }

    /// Drops entries for origins this device holds no operations from. They
    /// never select an operation to send, and keeping them could exceed the
    /// origin limit that loading enforces.
    mutating func retain(origins: [ReplicaDeviceID]) {
        let kept = Set(origins)
        own = own.map { $0.retaining(kept) }
        provided = provided.map { $0.retaining(kept) }
    }

    private static func lower(_ current: ReplicaVersionVector?, _ vector: ReplicaVersionVector) -> ReplicaVersionVector {
        guard let current else { return vector }
        var result = ReplicaVersionVector()
        for origin in current.origins {
            result.setSequence(min(current[origin], vector[origin]), for: origin)
        }
        return result
    }

    static func load(from url: URL) throws -> ReplyObligation? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let stored = try ReplicaCanonicalJSON.decode(ReplyObligation.self, from: Data(contentsOf: url))
        guard stored.version == version, (stored.recipients ?? []).count <= SyncGroupProfile.supportedMemberCeiling,
              (stored.bootstrap ?? []).count <= SyncGroupProfile.supportedMemberCeiling
        else {
            throw ReplicaError.corruptArchive("The reply obligation is unreadable.")
        }
        return stored.isEmpty ? nil : stored
    }

    static func save(_ obligation: ReplyObligation?, to url: URL) throws {
        guard let obligation, !obligation.isEmpty else {
            try remove(at: url)
            return
        }
        try ProtectedStorage.write(ReplicaCanonicalJSON.encode(obligation), to: url)
    }

    static func remove(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

private extension ReplicaVersionVector {
    mutating func raise(_ operation: TaskOperation) {
        setSequence(max(self[operation.originDeviceID], operation.originSequence), for: operation.originDeviceID)
    }

    mutating func raise(_ origin: ReplicaDeviceID, to sequence: UInt64) {
        setSequence(max(self[origin], sequence), for: origin)
    }

    func retaining(_ kept: Set<ReplicaDeviceID>) -> ReplicaVersionVector {
        var result = ReplicaVersionVector()
        for origin in origins where kept.contains(origin) {
            result.setSequence(self[origin], for: origin)
        }
        return result
    }
}
