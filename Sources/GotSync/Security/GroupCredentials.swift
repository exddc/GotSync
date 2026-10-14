import CryptoKit
import Foundation

enum GroupCredentialsError: Error, Equatable {
    case invalidCredentials
    case groupAtCapacity
}

/// Active membership status for a device in a Private Sync group.
enum GroupMemberStatus: String, Codable, Equatable, Sendable {
    case active
    case leaving
    case removed
}

/// One device in a group roster.
struct GroupMember: Equatable, Sendable, Hashable {
    let deviceID: Data
    let joinedEpoch: UInt64
    let status: GroupMemberStatus
    /// Ed25519 public key (32 bytes). Empty until learned (TOFU on first signed gossip).
    let signingPublicKey: Data

    init(
        deviceID: Data,
        joinedEpoch: UInt64 = 1,
        status: GroupMemberStatus = .active,
        signingPublicKey: Data = Data()
    ) {
        self.deviceID = deviceID
        self.joinedEpoch = joinedEpoch
        self.status = status
        self.signingPublicKey = signingPublicKey
    }

    var isActive: Bool {
        status == .active
    }

    var hasSigningPublicKey: Bool {
        signingPublicKey.count == 32
    }
}

extension GroupMember: Codable {
    private enum CodingKeys: String, CodingKey {
        case deviceID
        case joinedEpoch
        case status
        case signingPublicKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try container.decode(Data.self, forKey: .deviceID)
        joinedEpoch = try container.decodeIfPresent(UInt64.self, forKey: .joinedEpoch) ?? 1
        status = try container.decodeIfPresent(GroupMemberStatus.self, forKey: .status) ?? .active
        signingPublicKey = try container.decodeIfPresent(Data.self, forKey: .signingPublicKey) ?? Data()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(joinedEpoch, forKey: .joinedEpoch)
        try container.encode(status, forKey: .status)
        try container.encode(signingPublicKey, forKey: .signingPublicKey)
    }
}

/// Device-local group credentials (Keychain ThisDeviceOnly).
///
/// Replaces pair-era `PairCredentials` for linked state. Founding still uses the
/// pair ceremony; active storage is always a group snapshot.
struct GroupCredentials: Equatable, Sendable {
    static let credentialVersion: UInt8 = 2

    let version: UInt8
    let groupID: Data
    let epoch: UInt64
    let groupRoot: Data
    let localDeviceID: Data
    let members: [GroupMember]
    let membershipGeneration: UInt64
    /// Pair-era host/joiner for N=2 live handshake only. Nil after third member.
    let foundingPairRole: DeviceRole?
    let pairingArchiveHash: Data?
    /// Local-only Ed25519 private key (32 bytes). Never gossiped.
    let localSigningPrivateKey: Data

    init(
        groupID: Data,
        epoch: UInt64 = 1,
        groupRoot: Data,
        localDeviceID: Data,
        members: [GroupMember],
        membershipGeneration: UInt64 = 1,
        foundingPairRole: DeviceRole? = nil,
        pairingArchiveHash: Data? = nil,
        localSigningPrivateKey: Data? = nil
    ) {
        version = Self.credentialVersion
        self.groupID = groupID
        self.epoch = epoch
        self.groupRoot = groupRoot
        self.localDeviceID = localDeviceID
        self.membershipGeneration = membershipGeneration
        self.foundingPairRole = foundingPairRole
        self.pairingArchiveHash = pairingArchiveHash

        let privateKey: Curve25519.Signing.PrivateKey
        if let localSigningPrivateKey,
           localSigningPrivateKey.count == 32,
           let parsed = try? Curve25519.Signing.PrivateKey(
               rawRepresentation: localSigningPrivateKey
           )
        {
            privateKey = parsed
        } else {
            privateKey = Curve25519.Signing.PrivateKey()
        }
        self.localSigningPrivateKey = Data(privateKey.rawRepresentation)
        let localPublic = Data(privateKey.publicKey.rawRepresentation)
        let stamped = members.map { member in
            guard member.deviceID == localDeviceID else {
                return member
            }
            if member.signingPublicKey == localPublic {
                return member
            }
            return GroupMember(
                deviceID: member.deviceID,
                joinedEpoch: member.joinedEpoch,
                status: member.status,
                signingPublicKey: localPublic
            )
        }
        self.members = Self.normalized(stamped)
    }
}

extension GroupCredentials: Codable {
    private enum CodingKeys: String, CodingKey {
        case version
        case groupID
        case epoch
        case groupRoot
        case localDeviceID
        case members
        case membershipGeneration
        case foundingPairRole
        case pairingArchiveHash
        case localSigningPrivateKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let groupID = try container.decode(Data.self, forKey: .groupID)
        let epoch = try container.decodeIfPresent(UInt64.self, forKey: .epoch) ?? 1
        let groupRoot = try container.decode(Data.self, forKey: .groupRoot)
        let localDeviceID = try container.decode(Data.self, forKey: .localDeviceID)
        let members = try container.decode([GroupMember].self, forKey: .members)
        let membershipGeneration =
            try container.decodeIfPresent(UInt64.self, forKey: .membershipGeneration) ?? 1
        let foundingPairRole =
            try container.decodeIfPresent(DeviceRole.self, forKey: .foundingPairRole)
        let pairingArchiveHash =
            try container.decodeIfPresent(Data.self, forKey: .pairingArchiveHash)
        let localSigningPrivateKey =
            try container.decodeIfPresent(Data.self, forKey: .localSigningPrivateKey)
        self.init(
            groupID: groupID,
            epoch: epoch,
            groupRoot: groupRoot,
            localDeviceID: localDeviceID,
            members: members,
            membershipGeneration: membershipGeneration,
            foundingPairRole: foundingPairRole,
            pairingArchiveHash: pairingArchiveHash,
            localSigningPrivateKey: localSigningPrivateKey
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(groupID, forKey: .groupID)
        try container.encode(epoch, forKey: .epoch)
        try container.encode(groupRoot, forKey: .groupRoot)
        try container.encode(localDeviceID, forKey: .localDeviceID)
        try container.encode(members, forKey: .members)
        try container.encode(membershipGeneration, forKey: .membershipGeneration)
        try container.encodeIfPresent(foundingPairRole, forKey: .foundingPairRole)
        try container.encodeIfPresent(pairingArchiveHash, forKey: .pairingArchiveHash)
        try container.encode(localSigningPrivateKey, forKey: .localSigningPrivateKey)
    }
}

extension GroupCredentials {

    /// Bridge from a completed two-device pair ceremony.
    init(pair: PairCredentials) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let localPublic = Data(privateKey.publicKey.rawRepresentation)
        let local = GroupMember(
            deviceID: pair.localDeviceID,
            joinedEpoch: 1,
            signingPublicKey: localPublic
        )
        let remote = GroupMember(deviceID: pair.remoteDeviceID, joinedEpoch: 1)
        self.init(
            groupID: pair.pairID,
            epoch: 1,
            groupRoot: pair.pairRoot,
            localDeviceID: pair.localDeviceID,
            members: [local, remote],
            membershipGeneration: 1,
            foundingPairRole: pair.role,
            pairingArchiveHash: pair.pairingArchiveHash,
            localSigningPrivateKey: Data(privateKey.rawRepresentation)
        )
    }

    var localSigningPublicKey: Data {
        members.first(where: { $0.deviceID == localDeviceID })?.signingPublicKey
            ?? Data()
    }

    func signingPrivateKey() throws -> Curve25519.Signing.PrivateKey {
        guard localSigningPrivateKey.count == 32 else {
            throw GroupCredentialsError.invalidCredentials
        }
        return try Curve25519.Signing.PrivateKey(
            rawRepresentation: localSigningPrivateKey
        )
    }

    var activeMembers: [GroupMember] {
        members.filter(\.isActive)
    }

    var activeMemberDeviceIDs: [Data] {
        activeMembers.map(\.deviceID)
    }

    var activeMemberCount: Int {
        activeMembers.count
    }

    var remoteActiveDeviceIDs: [Data] {
        activeMemberDeviceIDs.filter { $0 != localDeviceID }
    }

    var isAtCapacity: Bool {
        activeMemberCount >= ReplicaLimits.maxOrigins
    }

    var supportsPairLiveHandshake: Bool {
        activeMemberCount == 2 && foundingPairRole != nil
    }

    /// Pair-compatible view for N=2 live/session helpers.
    var pairBridge: PairCredentials? {
        guard
            supportsPairLiveHandshake,
            let role = foundingPairRole,
            let remote = remoteActiveDeviceIDs.first
        else {
            return nil
        }
        return PairCredentials(
            pairRoot: groupRoot,
            pairID: groupID,
            role: role,
            localDeviceID: localDeviceID,
            remoteDeviceID: remote,
            pairingArchiveHash: pairingArchiveHash
        )
    }

    func validate(deviceID: ReplicaDeviceID) throws {
        guard
            version == Self.credentialVersion || version == 1,
            groupID.count == 16,
            groupRoot.count == 32,
            localDeviceID == deviceID.bytes,
            epoch >= 1,
            membershipGeneration >= 1,
            activeMemberCount >= 2,
            activeMemberCount <= ReplicaLimits.maxOrigins,
            activeMembers.contains(where: { $0.deviceID == localDeviceID }),
            Set(activeMemberDeviceIDs).count == activeMemberDeviceIDs.count,
            localSigningPrivateKey.count == 32
        else {
            throw GroupCredentialsError.invalidCredentials
        }
        for member in members {
            guard member.deviceID.count == 16 else {
                throw GroupCredentialsError.invalidCredentials
            }
            guard member.signingPublicKey.isEmpty || member.signingPublicKey.count == 32 else {
                throw GroupCredentialsError.invalidCredentials
            }
        }
    }

    func addingMember(
        deviceID: Data,
        joinedEpoch: UInt64? = nil,
        signingPublicKey: Data = Data()
    ) throws -> GroupCredentials {
        guard deviceID.count == 16, deviceID != localDeviceID else {
            throw GroupCredentialsError.invalidCredentials
        }
        if activeMembers.contains(where: { $0.deviceID == deviceID }) {
            return self
        }
        guard !isAtCapacity else {
            throw GroupCredentialsError.groupAtCapacity
        }
        guard signingPublicKey.isEmpty || signingPublicKey.count == 32 else {
            throw GroupCredentialsError.invalidCredentials
        }
        var next = activeMembers
        next.append(
            GroupMember(
                deviceID: deviceID,
                joinedEpoch: joinedEpoch ?? epoch,
                status: .active,
                signingPublicKey: signingPublicKey
            )
        )
        return GroupCredentials(
            groupID: groupID,
            epoch: epoch,
            groupRoot: groupRoot,
            localDeviceID: localDeviceID,
            members: next,
            membershipGeneration: membershipGeneration &+ 1,
            foundingPairRole: next.count == 2 ? foundingPairRole : nil,
            pairingArchiveHash: pairingArchiveHash,
            localSigningPrivateKey: localSigningPrivateKey
        )
    }

    /// Remove a remote member and advance the epoch with a rekey seed.
    func removingMember(
        deviceID: Data,
        rekeySeed: Data? = nil
    ) throws -> GroupCredentials {
        try removingMemberWithRekey(deviceID: deviceID, rekeySeed: rekeySeed).credentials
    }

    /// Remove + rekey; returns seed so membership gossip can carry it.
    func removingMemberWithRekey(
        deviceID: Data,
        rekeySeed: Data? = nil
    ) throws -> (credentials: GroupCredentials, rekeySeed: Data) {
        guard deviceID.count == 16, deviceID != localDeviceID else {
            throw GroupCredentialsError.invalidCredentials
        }
        let seed = try rekeySeed ?? Data.secureRandom(count: 32)
        guard seed.count == 32 else {
            throw GroupCredentialsError.invalidCredentials
        }
        let next = activeMembers.filter { $0.deviceID != deviceID }
        guard next.count >= 2 else {
            throw GroupCredentialsError.invalidCredentials
        }
        let nextRoot = SyncKeyDerivation.groupRootRekey(
            groupRoot: groupRoot,
            rekeySeed: seed
        )
        let credentials = GroupCredentials(
            groupID: groupID,
            epoch: epoch &+ 1,
            groupRoot: nextRoot,
            localDeviceID: localDeviceID,
            members: next,
            membershipGeneration: membershipGeneration &+ 1,
            foundingPairRole: next.count == 2 ? foundingPairRole : nil,
            pairingArchiveHash: pairingArchiveHash,
            localSigningPrivateKey: localSigningPrivateKey
        )
        return (credentials, seed)
    }

    /// Prepare a voluntary leave: remaining roster, bumped epoch/generation, rekey seed.
    func preparingLocalLeave() throws -> (
        remainingMembers: [GroupMember],
        nextEpoch: UInt64,
        nextGeneration: UInt64,
        nextGroupRoot: Data,
        rekeySeed: Data
    ) {
        let remaining = activeMembers.filter { $0.deviceID != localDeviceID }
        guard remaining.count >= 2 else {
            // Last peer leaving leaves a solo device — treat as unlink only.
            throw GroupCredentialsError.invalidCredentials
        }
        let seed = try Data.secureRandom(count: 32)
        let nextRoot = SyncKeyDerivation.groupRootRekey(
            groupRoot: groupRoot,
            rekeySeed: seed
        )
        return (
            remaining,
            epoch &+ 1,
            membershipGeneration &+ 1,
            nextRoot,
            seed
        )
    }

    /// Local leave: remaining roster without self (caller publishes then clears).
    func rosterAfterLocalLeave() -> [GroupMember] {
        activeMembers.filter { $0.deviceID != localDeviceID }
    }

    func replacingRoster(
        members: [GroupMember],
        membershipGeneration: UInt64,
        epoch: UInt64? = nil,
        groupRoot: Data? = nil
    ) throws -> GroupCredentials {
        let normalized = Self.normalized(members).filter(\.isActive)
        guard
            normalized.count >= 2,
            normalized.count <= ReplicaLimits.maxOrigins,
            normalized.contains(where: { $0.deviceID == localDeviceID }),
            membershipGeneration >= self.membershipGeneration
        else {
            throw GroupCredentialsError.invalidCredentials
        }
        return GroupCredentials(
            groupID: groupID,
            epoch: epoch ?? self.epoch,
            groupRoot: groupRoot ?? self.groupRoot,
            localDeviceID: localDeviceID,
            members: normalized,
            membershipGeneration: membershipGeneration,
            foundingPairRole: normalized.count == 2 ? foundingPairRole : nil,
            pairingArchiveHash: pairingArchiveHash,
            localSigningPrivateKey: localSigningPrivateKey
        )
    }

    /// Merge public keys learned from a signed snapshot (device ID match only).
    func mergingPublicKeys(from snapshotMembers: [GroupMember]) -> GroupCredentials {
        var byID = Dictionary(
            uniqueKeysWithValues: activeMembers.map { ($0.deviceID, $0) }
        )
        for remote in snapshotMembers {
            guard var existing = byID[remote.deviceID] else { continue }
            if !existing.hasSigningPublicKey, remote.hasSigningPublicKey {
                existing = GroupMember(
                    deviceID: existing.deviceID,
                    joinedEpoch: existing.joinedEpoch,
                    status: existing.status,
                    signingPublicKey: remote.signingPublicKey
                )
                byID[remote.deviceID] = existing
            }
        }
        return GroupCredentials(
            groupID: groupID,
            epoch: epoch,
            groupRoot: groupRoot,
            localDeviceID: localDeviceID,
            members: Array(byID.values),
            membershipGeneration: membershipGeneration,
            foundingPairRole: foundingPairRole,
            pairingArchiveHash: pairingArchiveHash,
            localSigningPrivateKey: localSigningPrivateKey
        )
    }

    private static func normalized(_ members: [GroupMember]) -> [GroupMember] {
        var seen = Set<Data>()
        var result: [GroupMember] = []
        for member in members.sorted(by: { $0.deviceID.lexicographicallyPrecedes($1.deviceID) }) {
            guard seen.insert(member.deviceID).inserted else {
                continue
            }
            result.append(member)
        }
        return result
    }
}

extension SyncKeyDerivation {
    static func groupRoot(from pairRoot: Data) -> Data {
        derive(
            input: pairRoot,
            label: "\(ProtocolDomains.namespace)/group-root/v1",
            count: 32
        )
    }

    static func groupID(from pairRoot: Data) -> Data {
        derive(
            input: pairRoot,
            label: "\(ProtocolDomains.namespace)/group-id/v1",
            count: 16
        )
    }

    /// `groupRoot_{e+1} = HKDF(groupRoot_e || rekeySeed, …/group-root-rekey/v1)`.
    static func groupRootRekey(groupRoot: Data, rekeySeed: Data) -> Data {
        derive(
            input: groupRoot + rekeySeed,
            label: "\(ProtocolDomains.namespace)/group-root-rekey/v1",
            count: 32
        )
    }

    static func groupLiveRoute(groupRoot: Data, epoch: UInt64) -> Data {
        var context = Data(count: 8)
        for index in 0..<8 {
            context[index] = UInt8((epoch >> (8 * (7 - index))) & 0xff)
        }
        return derive(
            input: groupRoot,
            label: "\(ProtocolDomains.namespace)/group-live-route/v1",
            context: context,
            count: 32
        )
    }

    static func groupLivePSK(groupRoot: Data, epoch: UInt64) -> Data {
        var context = Data(count: 8)
        for index in 0..<8 {
            context[index] = UInt8((epoch >> (8 * (7 - index))) & 0xff)
        }
        return derive(
            input: groupRoot,
            label: "\(ProtocolDomains.namespace)/group-live-psk/v1",
            context: context,
            count: 32
        )
    }
}
