import CryptoKit
import Foundation
import GotSyncMLS
import XCTest
@testable import GotSync

/// Control-only MLS processing used by host departures: group state, cursor
/// and speaker evidence advance, application plaintext is never stored.
final class HostControlOnlyTests: XCTestCase {
    private var root: URL!
    private var stores: [String: MemorySecretStore] = [:]

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        stores = [:]
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func session(_ name: String, transport: any MLSRelayTransport) throws -> MLSSession {
        let store = stores[name] ?? MemorySecretStore()
        stores[name] = store
        return try MLSSession(
            directory: MLSSession.directory(in: root.appendingPathComponent(name)),
            deviceID: Data(SHA256.hash(data: Data(name.utf8))).prefix(16),
            secretStore: store,
            transport: transport,
            fetchLimit: 2
        )
    }

    private func admit(_ joining: MLSSession, by inviter: MLSSession, group: Data) async throws {
        let token = try Data.secureRandom(count: 32)
        let published = try await joining.publishKeyPackage(pairingToken: token, profile: nil)
        let keyPackage = try await XCTUnwrapAsync(await inviter.fetchKeyPackage(reference: published.reference, pairingToken: token))
        let added = try await inviter.add(keyPackage: keyPackage, verifiedFingerprint: published.fingerprint, reference: published.reference)
        guard case .accepted = added else { return XCTFail("Add was not accepted: \(added)") }
        let joined = try await joining.join(
            group: group, keyPackageReference: published.reference,
            verifiedInviterFingerprint: inviter.fingerprint(), profile: nil
        )
        XCTAssertTrue(joined)
    }

    func testControlOnlyKeepsCursorAndSpeakersButNoPlaintext() async throws {
        let relay = FakeMLSRelay()
        let alice = try session("alice", transport: relay)
        let bob = try session("bob", transport: relay)
        let carol = try session("carol", transport: relay)
        let group = try Data.secureRandom(count: 32)
        try await alice.createGroup(group, profile: nil)
        try await admit(bob, by: alice, group: group)
        try await admit(carol, by: alice, group: group)
        try await bob.synchronize()
        _ = try await alice.send(Data("before".utf8))
        try await bob.synchronize()
        let first = try await bob.inbox()
        XCTAssertEqual(first.map(\.plaintext), [Data("before".utf8)])

        try await bob.setControlOnly()
        let controlOnly = try await bob.isControlOnly()
        XCTAssertTrue(controlOnly)
        let cleared = try await bob.inbox()
        XCTAssertEqual(cleared, [])
        _ = try await carol.send(Data("after".utf8))
        _ = try await alice.send(Data("later".utf8))
        let before = try await bob.cursor()
        try await bob.synchronize()
        let after = try await bob.cursor()
        XCTAssertGreaterThan(after, before)
        let inbox = try await bob.inbox()
        XCTAssertEqual(inbox, [], "post-cut application plaintext was stored")
        let carolFingerprint = try await carol.fingerprint()
        let speakers = try await bob.spokenMembers()
        XCTAssertTrue(speakers.contains(carolFingerprint), "speaker evidence was not kept")

        let reopened = try session("bob", transport: relay)
        let persisted = try await reopened.isControlOnly()
        XCTAssertTrue(persisted)
        _ = try await alice.send(Data("after reopen".utf8))
        try await reopened.synchronize()
        let reopenedInbox = try await reopened.inbox()
        XCTAssertEqual(reopenedInbox, [])
    }

    func testControlOnlyLeaveStillWithdrawsASilentMemberAndKeepsOneThatSpoke() async throws {
        let relay = FakeMLSRelay()
        let alice = try session("alice", transport: relay)
        let bob = try session("bob", transport: relay)
        let carol = try session("carol", transport: relay)
        let dave = try session("dave", transport: relay)
        let group = try Data.secureRandom(count: 32)
        try await alice.createGroup(group, profile: nil)
        try await admit(bob, by: alice, group: group)
        try await admit(carol, by: bob, group: group)
        try await admit(dave, by: bob, group: group)
        try await alice.synchronize()
        try await bob.synchronize()
        try await bob.setControlOnly()
        _ = try await carol.send(Data("carol spoke".utf8))
        let carolFingerprint = try await carol.fingerprint()
        let daveFingerprint = try await dave.fingerprint()
        try await bob.leave(withdrawing: [carolFingerprint, daveFingerprint])
        let bobInbox = try await bob.inbox()
        XCTAssertEqual(bobInbox, [])
        try await alice.synchronize()
        _ = try await alice.flush()
        try await alice.synchronize()
        let members = Set(try await alice.members().map(\.fingerprint))
        XCTAssertTrue(members.contains(carolFingerprint), "a member that spoke was withdrawn")
        XCTAssertFalse(members.contains(daveFingerprint), "a silent member stayed")
    }

    func testDemoSessionsStillKeepPlaintext() async throws {
        let relay = FakeMLSRelay()
        let alice = try session("alice", transport: relay)
        let bob = try session("bob", transport: relay)
        let group = try Data.secureRandom(count: 32)
        try await alice.createGroup(group, profile: nil)
        try await admit(bob, by: alice, group: group)
        _ = try await alice.send(Data("kept".utf8))
        try await bob.synchronize()
        let controlOnly = try await bob.isControlOnly()
        XCTAssertFalse(controlOnly)
        let kept = try await bob.inbox()
        XCTAssertEqual(kept.map(\.plaintext), [Data("kept".utf8)])
    }
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
