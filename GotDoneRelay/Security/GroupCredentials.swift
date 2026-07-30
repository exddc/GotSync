import Foundation

/// Active membership status for a device in a Private Sync group.
enum GroupMemberStatus: String, Codable, Equatable, Sendable {
    case active
    case leaving
    case removed
}

/// One device in a group roster.
struct GroupMember: Codable, Equatable, Sendable, Hashable {
    let deviceID: Data
    let joinedEpoch: UInt64
    let status: GroupMemberStatus

    init(
        deviceID: Data,
        joinedEpoch: UInt64 = 1,
        status: GroupMemberStatus = .active
    ) {
        self.deviceID = deviceID
        self.joinedEpoch = joinedEpoch
        self.status = status
    }

    var isActive: Bool {
        status == .active
    }
}

/// Device-local group credentials (Keychain ThisDeviceOnly).
///
/// Replaces pair-era `PairCredentials` for linked state. Founding still uses the
/// pair ceremony; active storage is always a group snapshot.
struct GroupCredentials: Codable, Equatable, Sendable {
    static let credentialVersion: UInt8 = 1

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

    init(
        groupID: Data,
        epoch: UInt64 = 1,
        groupRoot: Data,
        localDeviceID: Data,
        members: [GroupMember],
        membershipGeneration: UInt64 = 1,
        foundingPairRole: DeviceRole? = nil,
        pairingArchiveHash: Data? = nil
    ) {
        version = Self.credentialVersion
        self.groupID = groupID
        self.epoch = epoch
        self.groupRoot = groupRoot
        self.localDeviceID = localDeviceID
        self.members = Self.normalized(members)
        self.membershipGeneration = membershipGeneration
        self.foundingPairRole = foundingPairRole
        self.pairingArchiveHash = pairingArchiveHash
    }

    /// Bridge from a completed two-device pair ceremony.
    init(pair: PairCredentials) {
        let local = GroupMember(deviceID: pair.localDeviceID, joinedEpoch: 1)
        let remote = GroupMember(deviceID: pair.remoteDeviceID, joinedEpoch: 1)
        self.init(
            groupID: pair.pairID,
            epoch: 1,
            groupRoot: pair.pairRoot,
            localDeviceID: pair.localDeviceID,
            members: [local, remote],
            membershipGeneration: 1,
            foundingPairRole: pair.role,
            pairingArchiveHash: pair.pairingArchiveHash
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
        activeMemberCount >= ProductSyncPolicy.maxDevices
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
            version == Self.credentialVersion,
            groupID.count == 16,
            groupRoot.count == 32,
            localDeviceID == deviceID.bytes,
            epoch >= 1,
            membershipGeneration >= 1,
            activeMemberCount >= 2,
            activeMemberCount <= ProductSyncPolicy.maxDevices,
            activeMembers.contains(where: { $0.deviceID == localDeviceID }),
            Set(activeMemberDeviceIDs).count == activeMemberDeviceIDs.count
        else {
            throw SyncAppError.invalidCredentials
        }
        for member in members {
            guard member.deviceID.count == 16 else {
                throw SyncAppError.invalidCredentials
            }
        }
    }

    func addingMember(
        deviceID: Data,
        joinedEpoch: UInt64? = nil
    ) throws -> GroupCredentials {
        guard deviceID.count == 16, deviceID != localDeviceID else {
            throw SyncAppError.invalidCredentials
        }
        if activeMembers.contains(where: { $0.deviceID == deviceID }) {
            return self
        }
        guard !isAtCapacity else {
            throw SyncAppError.groupAtCapacity
        }
        var next = activeMembers
        next.append(
            GroupMember(
                deviceID: deviceID,
                joinedEpoch: joinedEpoch ?? epoch,
                status: .active
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
            pairingArchiveHash: pairingArchiveHash
        )
    }

    func removingMember(deviceID: Data) throws -> GroupCredentials {
        guard deviceID.count == 16, deviceID != localDeviceID else {
            throw SyncAppError.invalidCredentials
        }
        let next = activeMembers.filter { $0.deviceID != deviceID }
        guard next.count >= 2 else {
            throw SyncAppError.invalidCredentials
        }
        return GroupCredentials(
            groupID: groupID,
            epoch: epoch,
            groupRoot: groupRoot,
            localDeviceID: localDeviceID,
            members: next,
            membershipGeneration: membershipGeneration &+ 1,
            foundingPairRole: next.count == 2 ? foundingPairRole : nil,
            pairingArchiveHash: pairingArchiveHash
        )
    }

    func replacingRoster(
        members: [GroupMember],
        membershipGeneration: UInt64,
        epoch: UInt64? = nil
    ) throws -> GroupCredentials {
        let normalized = Self.normalized(members).filter(\.isActive)
        guard
            normalized.count >= 2,
            normalized.count <= ProductSyncPolicy.maxDevices,
            normalized.contains(where: { $0.deviceID == localDeviceID }),
            membershipGeneration >= self.membershipGeneration
        else {
            throw SyncAppError.invalidCredentials
        }
        return GroupCredentials(
            groupID: groupID,
            epoch: epoch ?? self.epoch,
            groupRoot: groupRoot,
            localDeviceID: localDeviceID,
            members: normalized,
            membershipGeneration: membershipGeneration,
            foundingPairRole: normalized.count == 2 ? foundingPairRole : nil,
            pairingArchiveHash: pairingArchiveHash
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
            label: "com.gotdone.sync/group-root/v1",
            count: 32
        )
    }

    static func groupID(from pairRoot: Data) -> Data {
        derive(
            input: pairRoot,
            label: "com.gotdone.sync/group-id/v1",
            count: 16
        )
    }

    static func groupLiveRoute(groupRoot: Data, epoch: UInt64) -> Data {
        var context = Data(count: 8)
        for index in 0..<8 {
            context[index] = UInt8((epoch >> (8 * (7 - index))) & 0xff)
        }
        return derive(
            input: groupRoot,
            label: "com.gotdone.sync/group-live-route/v1",
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
            label: "com.gotdone.sync/group-live-psk/v1",
            context: context,
            count: 32
        )
    }
}
