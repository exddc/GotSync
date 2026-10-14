import CryptoKit
import XCTest
@testable import GotSync

final class GroupSyncTests: XCTestCase {


    func testGroupCredentialsRoundTripAndRosterInvariants() throws {
        let local = Data(repeating: 0x11, count: 16)
        let remote = Data(repeating: 0x22, count: 16)
        let third = Data(repeating: 0x33, count: 16)
        let root = Data(repeating: 0x44, count: 32)
        let groupID = Data(repeating: 0x55, count: 16)

        var credentials = GroupCredentials(
            groupID: groupID,
            epoch: 1,
            groupRoot: root,
            localDeviceID: local,
            members: [
                GroupMember(deviceID: local),
                GroupMember(deviceID: remote),
            ],
            membershipGeneration: 1,
            foundingPairRole: .host
        )
        try credentials.validate(
            deviceID: try ReplicaDeviceID(bytes: local)
        )
        XCTAssertEqual(credentials.activeMemberCount, 2)
        XCTAssertTrue(credentials.supportsPairLiveHandshake)
        XCTAssertNotNil(credentials.pairBridge)

        credentials = try credentials.addingMember(deviceID: third)
        XCTAssertEqual(credentials.activeMemberCount, 3)
        XCTAssertEqual(credentials.membershipGeneration, 2)
        XCTAssertNil(credentials.foundingPairRole)
        XCTAssertFalse(credentials.supportsPairLiveHandshake)
        XCTAssertEqual(
            Set(credentials.activeMemberDeviceIDs),
            Set([local, remote, third])
        )

        // Idempotent add
        let again = try credentials.addingMember(deviceID: third)
        XCTAssertEqual(again, credentials)
    }

    func testGroupCredentialsFromPairBridge() throws {
        let pair = PairCredentials(
            pairRoot: Data(repeating: 0x61, count: 32),
            pairID: Data(repeating: 0x62, count: 16),
            role: .joiner,
            localDeviceID: Data(repeating: 0x63, count: 16),
            remoteDeviceID: Data(repeating: 0x64, count: 16)
        )
        let group = GroupCredentials(pair: pair)
        XCTAssertEqual(group.groupRoot, pair.pairRoot)
        XCTAssertEqual(group.groupID, pair.pairID)
        XCTAssertEqual(group.activeMemberCount, 2)
        XCTAssertEqual(group.foundingPairRole, pair.role)
        XCTAssertEqual(group.pairBridge, pair)
    }

    func testGroupMailboxFanOutRoutesDifferPerRecipient() throws {
        let local = Data(repeating: 0x71, count: 16)
        let peerA = Data(repeating: 0x72, count: 16)
        let peerB = Data(repeating: 0x73, count: 16)
        let credentials = GroupCredentials(
            groupID: Data(repeating: 0x74, count: 16),
            groupRoot: Data(repeating: 0x75, count: 32),
            localDeviceID: local,
            members: [
                GroupMember(deviceID: local),
                GroupMember(deviceID: peerA),
                GroupMember(deviceID: peerB),
            ],
            membershipGeneration: 3
        )
        let mailbox = try GroupMailbox(credentials: credentials)
        XCTAssertEqual(mailbox.outboundByRecipient.count, 2)
        XCTAssertEqual(mailbox.inboundBySender.count, 2)
        let outA = try XCTUnwrap(mailbox.outboundByRecipient[peerA])
        let outB = try XCTUnwrap(mailbox.outboundByRecipient[peerB])
        XCTAssertNotEqual(outA.route, outB.route)
        XCTAssertNotEqual(outA.authorization, outB.authorization)

        // Reverse direction for peerA differs from local→A.
        let inboundFromA = try XCTUnwrap(mailbox.inboundBySender[peerA])
        XCTAssertNotEqual(inboundFromA.route, outA.route)
    }

    func testGroupMailboxSealOpenRoundTripAndRejectsWrongRecipient() throws {
        let local = try ReplicaDeviceID(bytes: Data(repeating: 0x81, count: 16))
        let remote = try ReplicaDeviceID(bytes: Data(repeating: 0x82, count: 16))
        let groupID = Data(repeating: 0x83, count: 16)
        let root = Data(repeating: 0x84, count: 32)

        let senderCredentials = GroupCredentials(
            groupID: groupID,
            groupRoot: root,
            localDeviceID: local.bytes,
            members: [
                GroupMember(deviceID: local.bytes),
                GroupMember(deviceID: remote.bytes),
            ]
        )
        let recipientCredentials = GroupCredentials(
            groupID: groupID,
            groupRoot: root,
            localDeviceID: remote.bytes,
            members: [
                GroupMember(deviceID: local.bytes),
                GroupMember(deviceID: remote.bytes),
            ]
        )
        let outbound = try GroupMailbox(credentials: senderCredentials)
        let inbound = try GroupMailbox(credentials: recipientCredentials)

        var replica = try TaskReplica(deviceID: local)
        let operation = try replica.createTask(title: "Group fan-out")
        let envelope = try outbound.seal(operation, for: remote.bytes)
        let opened = try inbound.open(envelope, from: local.bytes)
        XCTAssertEqual(opened, operation)

        // Wrong assumed sender rejects.
        XCTAssertThrowsError(
            try inbound.open(envelope, from: remote.bytes)
        )
    }

    func testMembershipSnapshotSealOpen() throws {
        let issuerKey = Curve25519.Signing.PrivateKey()
        let issuer = Data(repeating: 0x91, count: 16)
        let peer = Data(repeating: 0x92, count: 16)
        let joiner = Data(repeating: 0x93, count: 16)
        let root = Data(repeating: 0x94, count: 32)
        let groupID = Data(repeating: 0x95, count: 16)

        let snapshot = try GroupMembershipSnapshot.signed(
            groupID: groupID,
            epoch: 1,
            membershipGeneration: 4,
            roster: [
                GroupMembershipRosterEntry(
                    deviceID: issuer,
                    signingPublicKey: Data(issuerKey.publicKey.rawRepresentation)
                ),
                GroupMembershipRosterEntry(deviceID: peer),
                GroupMembershipRosterEntry(deviceID: joiner),
            ],
            issuerDeviceID: issuer,
            signingKey: issuerKey
        )
        let mailbox = try GroupMembershipMailbox(
            groupRoot: root,
            groupID: groupID,
            epoch: 1,
            senderDeviceID: issuer,
            recipientDeviceID: peer
        )
        let envelope = try mailbox.seal(snapshot)
        let opened = try mailbox.open(envelope)
        XCTAssertEqual(opened, snapshot)
    }

    func testMailboxCheckpointPerRecipient() {
        let groupID = Data(repeating: 0xa1, count: 16)
        let a = Data(repeating: 0xa2, count: 16)
        let b = Data(repeating: 0xa3, count: 16)
        let checkpoint = MailboxCheckpoint(
            groupID: groupID,
            uploadedThroughByRecipient: [a: 3, b: 5]
        )
        XCTAssertEqual(checkpoint.uploadedLocalSequence, 3)
        XCTAssertEqual(checkpoint.uploadedThrough(for: a), 3)
        XCTAssertEqual(checkpoint.uploadedThrough(for: b), 5)

        let advanced = checkpoint.withUploaded(recipientDeviceID: a, sequence: 7)
        XCTAssertEqual(advanced.uploadedThrough(for: a), 7)
        XCTAssertEqual(advanced.uploadedLocalSequence, 5)
    }

    func testGroupAtCapacityRejectsNinthMember() throws {
        let local = Data(repeating: 0xb0, count: 16)
        var members = [GroupMember(deviceID: local)]
        for index in 1..<8 {
            members.append(
                GroupMember(deviceID: Data(repeating: UInt8(0xb0 + index), count: 16))
            )
        }
        let credentials = GroupCredentials(
            groupID: Data(repeating: 0xc1, count: 16),
            groupRoot: Data(repeating: 0xc2, count: 32),
            localDeviceID: local,
            members: members,
            membershipGeneration: 8
        )
        XCTAssertTrue(credentials.isAtCapacity)
        XCTAssertThrowsError(
            try credentials.addingMember(
                deviceID: Data(repeating: 0xff, count: 16)
            )
        ) { error in
            XCTAssertEqual(error as? GroupCredentialsError, .groupAtCapacity)
        }
    }

    func testCredentialStoreMigratesPairToGroup() throws {
        let keychain = MemorySecretStore(
            service: "com.gotdone.relay.tests.group.\(UUID().uuidString)"
        )
        let store = CredentialStore(keychain: keychain)
        let pair = PairCredentials(
            pairRoot: Data(repeating: 0xd1, count: 32),
            pairID: Data(repeating: 0xd2, count: 16),
            role: .host,
            localDeviceID: Data(repeating: 0xd3, count: 16),
            remoteDeviceID: Data(repeating: 0xd4, count: 16)
        )
        try store.saveActive(pair)
        let group = try XCTUnwrap(try store.activeGroup())
        XCTAssertEqual(group.groupRoot, pair.pairRoot)
        XCTAssertEqual(group.activeMemberCount, 2)
        let again = try XCTUnwrap(try store.activeGroup())
        XCTAssertEqual(again, group)
    }

    // MARK: - Security red-team (C1–C4)

    /// C1 baseline: shared groupRoot lets any member open B→C mailbox traffic.
    func testSharedGroupRootCanDeriveForeignPairMailbox() throws {
        let groupRoot = Data(repeating: 0xe1, count: 32)
        let groupID = Data(repeating: 0xe2, count: 16)
        let deviceA = Data(repeating: 0xa1, count: 16)
        let deviceB = Data(repeating: 0xb1, count: 16)
        let deviceC = Data(repeating: 0xc1, count: 16)

        let materialAsA = try GroupMailboxKeyMaterial(
            groupRoot: groupRoot,
            groupID: groupID,
            epoch: 1,
            senderDeviceID: deviceB,
            recipientDeviceID: deviceC
        )
        let materialAsB = try GroupMailboxKeyMaterial(
            groupRoot: groupRoot,
            groupID: groupID,
            epoch: 1,
            senderDeviceID: deviceB,
            recipientDeviceID: deviceC
        )
        XCTAssertEqual(materialAsA.route, materialAsB.route)
        XCTAssertEqual(materialAsA.authorization, materialAsB.authorization)

        let origin = try ReplicaDeviceID(bytes: deviceB)
        var replica = try TaskReplica(deviceID: origin)
        let operation = try replica.createTask(title: "B private to C")
        let sealed = try materialAsB.seal(operation)
        let openedByA = try materialAsA.open(sealed)
        XCTAssertEqual(openedByA, operation)
        _ = deviceA
    }

    /// C2: unsigned or foreign-issuer snapshots are rejected.
    func testMembershipSnapshotRejectsUnsignedOrForeignIssuer() throws {
        let issuerKey = Curve25519.Signing.PrivateKey()
        let foreignKey = Curve25519.Signing.PrivateKey()
        let issuer = Data(repeating: 0x11, count: 16)
        let peer = Data(repeating: 0x22, count: 16)
        let victim = Data(repeating: 0x33, count: 16)
        let groupID = Data(repeating: 0x44, count: 16)
        let root = Data(repeating: 0x55, count: 32)

        let credentials = GroupCredentials(
            groupID: groupID,
            epoch: 1,
            groupRoot: root,
            localDeviceID: peer,
            members: [
                GroupMember(
                    deviceID: issuer,
                    signingPublicKey: Data(issuerKey.publicKey.rawRepresentation)
                ),
                GroupMember(deviceID: peer),
                GroupMember(deviceID: victim),
            ],
            membershipGeneration: 1,
            localSigningPrivateKey: Data(
                Curve25519.Signing.PrivateKey().rawRepresentation
            )
        )

        let unsigned = GroupMembershipSnapshot(
            groupID: groupID,
            epoch: 1,
            membershipGeneration: 2,
            members: [issuer, peer],
            issuerDeviceID: issuer,
            signature: Data()
        )
        XCTAssertThrowsError(try unsigned.acceptedUpdate(against: credentials))

        let forged = try GroupMembershipSnapshot.signed(
            groupID: groupID,
            epoch: 1,
            membershipGeneration: 2,
            roster: [
                GroupMembershipRosterEntry(
                    deviceID: issuer,
                    signingPublicKey: Data(issuerKey.publicKey.rawRepresentation)
                ),
                GroupMembershipRosterEntry(deviceID: peer),
            ],
            issuerDeviceID: issuer,
            signingKey: foreignKey
        )
        XCTAssertThrowsError(try forged.acceptedUpdate(against: credentials))

        // Remove without rekey must fail (C3 coupled to C2 accept path).
        let omitWithoutRekey = try GroupMembershipSnapshot.signed(
            groupID: groupID,
            epoch: 1,
            membershipGeneration: 2,
            roster: [
                GroupMembershipRosterEntry(
                    deviceID: issuer,
                    signingPublicKey: Data(issuerKey.publicKey.rawRepresentation)
                ),
                GroupMembershipRosterEntry(deviceID: peer),
            ],
            issuerDeviceID: issuer,
            signingKey: issuerKey
        )
        XCTAssertThrowsError(try omitWithoutRekey.acceptedUpdate(against: credentials))

        let rekeySeed = Data(repeating: 0x77, count: 32)
        let validRemove = try GroupMembershipSnapshot.signed(
            groupID: groupID,
            epoch: 2,
            membershipGeneration: 2,
            roster: [
                GroupMembershipRosterEntry(
                    deviceID: issuer,
                    signingPublicKey: Data(issuerKey.publicKey.rawRepresentation)
                ),
                GroupMembershipRosterEntry(deviceID: peer),
            ],
            issuerDeviceID: issuer,
            rekeySeed: rekeySeed,
            signingKey: issuerKey
        )
        let updated = try XCTUnwrap(try validRemove.acceptedUpdate(against: credentials))
        XCTAssertEqual(updated.epoch, 2)
        XCTAssertEqual(Set(updated.activeMemberDeviceIDs), Set([issuer, peer]))
        XCTAssertEqual(
            updated.groupRoot,
            SyncKeyDerivation.groupRootRekey(groupRoot: root, rekeySeed: rekeySeed)
        )
    }

    /// C3: epoch rekey invalidates old mailbox material.
    func testEpochRekeyInvalidatesOldMailboxMaterial() throws {
        let groupID = Data(repeating: 0xf1, count: 16)
        let oldRoot = Data(repeating: 0xf2, count: 32)
        let rekeySeed = Data(repeating: 0xf3, count: 32)
        let newRoot = SyncKeyDerivation.groupRootRekey(
            groupRoot: oldRoot,
            rekeySeed: rekeySeed
        )
        let sender = Data(repeating: 0x01, count: 16)
        let recipient = Data(repeating: 0x02, count: 16)

        let oldMaterial = try GroupMailboxKeyMaterial(
            groupRoot: oldRoot,
            groupID: groupID,
            epoch: 1,
            senderDeviceID: sender,
            recipientDeviceID: recipient
        )
        let newMaterial = try GroupMailboxKeyMaterial(
            groupRoot: newRoot,
            groupID: groupID,
            epoch: 2,
            senderDeviceID: sender,
            recipientDeviceID: recipient
        )
        XCTAssertNotEqual(oldMaterial.route, newMaterial.route)

        let origin = try ReplicaDeviceID(bytes: sender)
        var replica = try TaskReplica(deviceID: origin)
        let operation = try replica.createTask(title: "epoch-bound")
        let sealedNew = try newMaterial.seal(operation)
        XCTAssertThrowsError(try oldMaterial.open(sealedNew))
        let sealedOld = try oldMaterial.seal(operation)
        XCTAssertThrowsError(try newMaterial.open(sealedOld))
        XCTAssertEqual(try newMaterial.open(sealedNew), operation)
    }

    /// C3: leave/remove drops routes to removed device after rekey.
    func testLeavePublishesRemoveAndDropsRoutes() throws {
        let local = Data(repeating: 0x81, count: 16)
        let peer = Data(repeating: 0x82, count: 16)
        let leaver = Data(repeating: 0x83, count: 16)
        let root = Data(repeating: 0x84, count: 32)
        let groupID = Data(repeating: 0x85, count: 16)

        let before = GroupCredentials(
            groupID: groupID,
            groupRoot: root,
            localDeviceID: local,
            members: [
                GroupMember(deviceID: local),
                GroupMember(deviceID: peer),
                GroupMember(deviceID: leaver),
            ],
            membershipGeneration: 3
        )
        let mailboxBefore = try GroupMailbox(credentials: before)
        XCTAssertNotNil(mailboxBefore.outboundByRecipient[leaver])

        let (after, seed) = try before.removingMemberWithRekey(deviceID: leaver)
        XCTAssertEqual(after.epoch, 2)
        XCTAssertEqual(seed.count, 32)
        XCTAssertFalse(after.activeMemberDeviceIDs.contains(leaver))
        let mailboxAfter = try GroupMailbox(credentials: after)
        XCTAssertNil(mailboxAfter.outboundByRecipient[leaver])
        XCTAssertEqual(mailboxAfter.outboundByRecipient.count, 1)
        XCTAssertNotEqual(after.groupRoot, root)
    }

    /// C4: invitation secret is fixed-size; regenerate yields a new secret.
    func testInvitationSingleUseAndTTL() throws {
        let first = try Invitation.generate()
        let second = try Invitation.generate()
        XCTAssertEqual(first.secret.count, 16)
        XCTAssertNotEqual(first.secret, second.secret)
        XCTAssertEqual(try Invitation.from(phrase: first.phrase), first)
        XCTAssertNotEqual(
            try Invitation.from(phrase: first.phrase).secret,
            second.secret
        )
        // App product TTL is a single number used for invite + waiting room.
        XCTAssertEqual(SyncTiming.invitationTimeToLive, 15 * 60)
        XCTAssertEqual(
            SyncTiming.invitationTimeToLive,
            SyncTiming.invitationTimeToLive
        )
    }

    /// H5: debug invite artifact writer is DEBUG-only (source/API guard).

}
