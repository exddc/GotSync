import Foundation

/// Plaintext of one MLS application message in a host-journal group.
///
/// `records` carries opaque record envelopes. `complete` tells `member`
/// that this provider sent every record up to `through`. The remaining
/// kinds carry the same control fields as `ReplicationMessage` version 2.
///
/// Snapshot bootstrap adds optional fields that earlier libraries ignore:
/// `snapshotSchema` on a provider hello, and `snapshot` or
/// `snapshotRefusal` on `complete`.
struct HostJournalMessage: Codable, Equatable, Sendable {
    static let version = 3
    static let maxRecords = 256
    static let maxRecordBytes = 262_144

    enum Kind: String, Codable, Sendable {
        case records
        case hello
        case complete
        case reservation
        case release
        case reservations
    }

    let version: Int
    let kind: Kind
    var records: [Data]? = nil
    var vector: ReplicaVersionVector? = nil
    var provider: Data? = nil
    var member: Data? = nil
    var origins: [ReplicaDeviceID]? = nil
    var epoch: UInt64? = nil
    var reservation: UInt64? = nil
    var reservations: [OriginReservation]? = nil
    var overflowed: Bool? = nil
    var through: ReplicaVersionVector? = nil
    var snapshotSchema: String? = nil
    var snapshot: HostSnapshotOffer? = nil
    var snapshotRefusal: String? = nil

    static func records(_ envelopes: [Data]) -> HostJournalMessage {
        HostJournalMessage(version: version, kind: .records, records: envelopes)
    }

    static func complete(
        member: Data, through: ReplicaVersionVector, snapshot: HostSnapshotOffer? = nil, refusal: HostSnapshotRefusalReason? = nil
    ) -> HostJournalMessage {
        var message = HostJournalMessage(version: version, kind: .complete, member: member, through: through)
        message.snapshot = snapshot
        message.snapshotRefusal = snapshot == nil ? refusal?.rawValue : nil
        return message
    }

    /// The version 3 form of a control message. Operations have none.
    init(control: ReplicationMessage) throws {
        switch control.kind {
        case .operations:
            throw WireMessageError.invalidMessage
        case .hello:
            self.init(version: Self.version, kind: .hello, vector: control.vector, provider: control.provider)
        case .reservation:
            self.init(
                version: Self.version, kind: .reservation, member: control.member, origins: control.origins, epoch: control.epoch
            )
        case .release:
            self.init(version: Self.version, kind: .release, member: control.member, reservation: control.reservation)
        case .reservations:
            self.init(
                version: Self.version, kind: .reservations, member: control.member,
                reservations: control.reservations, overflowed: control.overflowed
            )
        }
    }

    private init(
        version: Int, kind: Kind, records: [Data]? = nil, vector: ReplicaVersionVector? = nil, provider: Data? = nil,
        member: Data? = nil, origins: [ReplicaDeviceID]? = nil, epoch: UInt64? = nil, reservation: UInt64? = nil,
        reservations: [OriginReservation]? = nil, overflowed: Bool? = nil, through: ReplicaVersionVector? = nil
    ) {
        self.version = version
        self.kind = kind
        self.records = records
        self.vector = vector
        self.provider = provider
        self.member = member
        self.origins = origins
        self.epoch = epoch
        self.reservation = reservation
        self.reservations = reservations
        self.overflowed = overflowed
        self.through = through
    }

    /// The engine's control value for a control kind; nil for records and completion.
    var control: ReplicationMessage? {
        switch kind {
        case .records, .complete:
            return nil
        case .hello:
            return .hello(vector: vector ?? ReplicaVersionVector(), provider: provider)
        case .reservation:
            return .reservation(member: member ?? Data(), origins: origins ?? [], epoch: epoch ?? 0)
        case .release:
            return .release(member: member ?? Data(), reservation: reservation ?? 0)
        case .reservations:
            return .reservations(reservations ?? [], overflowed: overflowed == true, for: member ?? Data())
        }
    }

    func encoded() throws -> Data {
        let data = try ReplicaCanonicalJSON.encode(self)
        guard data.count <= ProtocolLimits.plaintextBytes else { throw WireMessageError.messageTooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> HostJournalMessage {
        guard data.count <= ProtocolLimits.plaintextBytes else { throw WireMessageError.messageTooLarge }
        let message = try ReplicaCanonicalJSON.decode(HostJournalMessage.self, from: data)
        guard message.version == version else { throw WireMessageError.invalidVersion }
        let fields: [Bool] = [
            message.records != nil, message.vector != nil, message.provider != nil, message.member != nil,
            message.origins != nil, message.epoch != nil, message.reservation != nil, message.reservations != nil,
            message.overflowed != nil, message.through != nil, message.snapshotSchema != nil, message.snapshot != nil,
            message.snapshotRefusal != nil,
        ]
        func only(_ allowed: Set<Int>) -> Bool {
            fields.enumerated().allSatisfy { allowed.contains($0.offset) || !$0.element }
        }
        let valid: Bool
        switch message.kind {
        case .records:
            let records = message.records ?? []
            valid = only([0]) && (1...maxRecords).contains(records.count) && records.allSatisfy { !$0.isEmpty }
                && records.reduce(0) { $0 + $1.count } <= maxRecordBytes
        case .hello:
            valid = only([1, 2, 10]) && message.vector != nil && (message.provider.map { $0.count == 32 } ?? true)
                && (message.snapshotSchema.map { message.provider != nil && HostSnapshotSchemaName.isValid($0) } ?? true)
        case .complete:
            valid = only([3, 9, 11, 12]) && message.member?.count == 32 && message.through != nil
                && !(message.snapshot != nil && message.snapshotRefusal != nil)
                && (message.snapshotRefusal.map { $0.utf8.count <= 32 } ?? true)
        case .reservation:
            valid = only([3, 4, 5]) && message.member?.count == 32 && message.epoch != nil
                && message.origins.map(OriginReservation.isCanonical) == true
        case .release:
            valid = only([3, 6]) && message.member?.count == 32 && message.reservation != nil
        case .reservations:
            let entries = message.reservations ?? []
            valid = only([3, 7, 8]) && message.member?.count == 32 && message.reservations != nil
                && entries.count <= OriginReservation.maximumStored && (message.overflowed ?? true)
                && entries.allSatisfy { $0.member.count == 32 && $0.owner.count == 32 && OriginReservation.isCanonical($0.origins) }
        }
        guard valid else { throw WireMessageError.invalidMessage }
        return message
    }
}
