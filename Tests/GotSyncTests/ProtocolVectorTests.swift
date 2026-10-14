import CryptoKit
import Foundation
import XCTest
@testable import GotSync

final class ProtocolVectorTests: XCTestCase {
    func testVersionOneBytesMatchBaseline() throws {
        let root = Data(0..<32)
        let sender = Data(repeating: 0x11, count: 16)
        let recipient = Data(repeating: 0x22, count: 16)
        let pairID = Data(repeating: 0x33, count: 16)
        let invitation = try Invitation(secret: Data(0..<16))
        let device = try ReplicaDeviceID(bytes: sender)
        var replica = try TaskReplica(deviceID: device)
        let operation = try replica.createTask(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "Vector task")
        let pairMailbox = try MailboxKeyMaterial(pairRoot: root, pairID: pairID, senderRole: .host)
        let pairEnvelope = try pairMailbox.seal(operation)
        let groupMailbox = try GroupMailboxKeyMaterial(groupRoot: root, groupID: pairID, epoch: 1, senderDeviceID: sender, recipientDeviceID: recipient)
        let groupEnvelope = try groupMailbox.seal(operation)
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: root)
        let snapshot = try GroupMembershipSnapshot.signed(groupID: pairID, epoch: 1, membershipGeneration: 1, roster: [GroupMembershipRosterEntry(deviceID: sender, signingPublicKey: signingKey.publicKey.rawRepresentation), GroupMembershipRosterEntry(deviceID: recipient)], issuerDeviceID: sender, signingKey: signingKey)
        let provision = try PairingProvisionMailbox(pairRoot: root, pairID: pairID).seal(archive: replica.exportProvisioningArchive(), hostDeviceID: sender)
        let vector: [String: String] = [
            "invitationPhrase": invitation.phrase,
            "invitationRoute": invitation.pairRoute.hexString,
            "syncRoute": SyncKeyDerivation.syncRoute(pairRoot: root).hexString,
            "syncPSK": SyncKeyDerivation.syncPSK(pairRoot: root).hexString,
            "operation": String(decoding: try operation.canonicalData(), as: UTF8.self),
            "archive": String(decoding: try replica.atomicArchiveData(), as: UTF8.self),
            "syncWire": String(decoding: try WireCodec.encode(SyncWireMessage.hello(vector: replica.versionVector)), as: UTF8.self),
            "mailboxAuth": pairMailbox.authorization.hexString,
            "mailboxRoute": pairMailbox.route.hexString,
            "mailboxID": pairEnvelope.messageID.hexString,
            "mailboxPayload": pairEnvelope.ciphertext.hexString,
            "groupMailboxAuth": groupMailbox.authorization.hexString,
            "groupMailboxRoute": groupMailbox.route.hexString,
            "groupMailboxID": groupEnvelope.messageID.hexString,
            "groupMailboxPayload": groupEnvelope.ciphertext.hexString,
            "membership": String(decoding: try CanonicalJSON.encoder.encode(snapshot), as: UTF8.self),
            "provisionID": try XCTUnwrap(provision.first).messageID.hexString,
            "provisionPayload": try XCTUnwrap(provision.first).ciphertext.hexString,
        ]
        let url = try XCTUnwrap(Bundle.module.url(forResource: "protocol-v1", withExtension: "json", subdirectory: "Fixtures"))
        let baseline = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        for (key, value) in vector where key != "membership" {
            XCTAssertTrue(value == baseline[key], "Baseline differs for \(key)")
        }
        let baselineMembership = try XCTUnwrap(baseline["membership"])
        let archivedSnapshot = try CanonicalJSON.decoder.decode(GroupMembershipSnapshot.self, from: Data(baselineMembership.utf8))
        let body = try snapshot.unsignedCanonicalData()
        XCTAssertEqual(body, try archivedSnapshot.unsignedCanonicalData())
        XCTAssertTrue(signingKey.publicKey.isValidSignature(archivedSnapshot.signature, for: body))
        XCTAssertTrue(signingKey.publicKey.isValidSignature(snapshot.signature, for: body))
    }
}
