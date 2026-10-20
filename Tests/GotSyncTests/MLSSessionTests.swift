import CryptoKit
import Foundation
import GotSyncMLS
import XCTest
@testable import GotSync

final class MLSSessionTests: XCTestCase {
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

    private func pair(_ relay: any MLSRelayTransport) async throws -> (MLSSession, MLSSession, Data) {
        let alice = try session("alice", transport: relay)
        let bob = try session("bob", transport: relay)
        let group = try Data.secureRandom(count: 32)
        try await alice.createGroup(group)
        try await admit(bob, by: alice, group: group)
        return (alice, bob, group)
    }

    private func admit(_ joining: MLSSession, by inviter: MLSSession, group: Data) async throws {
        let token = try Data.secureRandom(count: 32)
        let published = try await joining.publishKeyPackage(pairingToken: token)
        let keyPackage = try await XCTUnwrapAsync(await inviter.fetchKeyPackage(reference: published.reference, pairingToken: token))
        let added = try await inviter.add(keyPackage: keyPackage, verifiedFingerprint: published.fingerprint, reference: published.reference)
        guard case .accepted = added else { return XCTFail("Add was not accepted: \(added)") }
        let joined = try await joining.join(
            group: group, keyPackageReference: published.reference,
            verifiedInviterFingerprint: inviter.fingerprint()
        )
        XCTAssertTrue(joined)
    }

    func testStateKeyLivesInSecretStoreAndReopensIdentity() async throws {
        let relay = FakeMLSRelay()
        let first = try session("alice", transport: relay)
        let fingerprint = try await first.fingerprint()
        let key = try XCTUnwrap(stores["alice"]?.read(account: SecretStoreMLSStateKey.account))
        XCTAssertEqual(key.count, 32)
        let reopened = try session("alice", transport: relay)
        let reopenedFingerprint = try await reopened.fingerprint()
        XCTAssertEqual(reopenedFingerprint, fingerprint)

        stores["alice"] = MemorySecretStore()
        XCTAssertThrowsError(try session("alice", transport: relay))
        try stores["alice"]?.write(Data(repeating: 1, count: 16), account: SecretStoreMLSStateKey.account)
        XCTAssertThrowsError(try session("alice", transport: relay)) { XCTAssertEqual($0 as? MLSStoreError, .unreadable) }
    }

    func testEraseRemovesStateAndKey() async throws {
        let relay = FakeMLSRelay()
        let first = try session("alice", transport: relay)
        let fingerprint = try await first.fingerprint()
        let directory = MLSSession.directory(in: root.appendingPathComponent("alice"))
        try MLSSession.erase(directory: directory, secretStore: XCTUnwrap(stores["alice"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNil(try stores["alice"]?.read(account: SecretStoreMLSStateKey.account))
        let fresh = try session("alice", transport: relay)
        let freshFingerprint = try await fresh.fingerprint()
        XCTAssertNotEqual(freshFingerprint, fingerprint)
    }

    func testAddJoinAndExchangeMessages() async throws {
        let relay = FakeMLSRelay()
        let (alice, bob, _) = try await pair(relay)
        let sent = try await alice.send(Data("hello".utf8))
        guard case .accepted(let cursor) = sent else { return XCTFail("Message not accepted") }
        let processed = try await bob.synchronize()
        XCTAssertEqual(processed, 1)
        let inbox = try await bob.inbox()
        let aliceFingerprint = try await alice.fingerprint()
        XCTAssertEqual(inbox.map(\.plaintext), [Data("hello".utf8)])
        XCTAssertEqual(inbox.first?.sender, aliceFingerprint)
        XCTAssertEqual(inbox.first?.cursor, cursor)
        let bobCursor = try await bob.cursor()
        XCTAssertEqual(bobCursor, cursor)
        let bobAuthorization = try await bob.transportAuthorizationForTesting()
        let acknowledged = await relay.acknowledged(by: bobAuthorization)
        XCTAssertEqual(acknowledged, cursor)
        try await bob.acknowledgeInbox(through: cursor)
        let drained = try await bob.inbox()
        XCTAssertTrue(drained.isEmpty)
        let aliceInbox = try await alice.inbox()
        XCTAssertTrue(aliceInbox.isEmpty)
        let pending = try await alice.pendingDelivery()
        XCTAssertNil(pending)
    }

    func testCursorSurvivesReopenAndCatchesUpOffline() async throws {
        let relay = FakeMLSRelay()
        let (alice, _, _) = try await pair(relay)
        for index in 0..<5 { _ = try await alice.send(Data("offline \(index)".utf8)) }
        let bob = try session("bob", transport: relay)
        try await bob.synchronize()
        let inbox = try await bob.inbox()
        XCTAssertEqual(inbox.map(\.plaintext), (0..<5).map { Data("offline \($0)".utf8) })
        let reopened = try session("bob", transport: relay)
        let processed = try await reopened.synchronize()
        XCTAssertEqual(processed, 0)
        let reopenedInbox = try await reopened.inbox()
        XCTAssertEqual(reopenedInbox.count, 5)
    }

    func testJoinBeforeAdmissionReportsNotJoined() async throws {
        let relay = FakeMLSRelay()
        let alice = try session("alice", transport: relay)
        let bob = try session("bob", transport: relay)
        let group = try Data.secureRandom(count: 32)
        try await alice.createGroup(group)
        let published = try await bob.publishKeyPackage(pairingToken: Data(repeating: 3, count: 32))
        let joined = try await bob.join(group: group, keyPackageReference: published.reference, verifiedInviterFingerprint: alice.fingerprint())
        XCTAssertFalse(joined)
        let bobGroup = try await bob.group()
        XCTAssertNil(bobGroup)
    }

    func testCreateGroupIsIdempotentAndRejectsSecondGroup() async throws {
        let relay = FakeMLSRelay()
        let alice = try session("alice", transport: relay)
        let group = Data(repeating: 4, count: 32)
        try await alice.createGroup(group)
        try await alice.createGroup(group)
        do {
            try await alice.createGroup(Data(repeating: 5, count: 32))
            XCTFail("Second group accepted")
        } catch { XCTAssertEqual(error as? MLSSessionError, .groupMismatch) }
    }

    func testLostAppendResponseIsRetriedWithoutDuplicates() async throws {
        let relay = FakeMLSRelay()
        let (alice, bob, _) = try await pair(relay)
        await relay.dropNextAppendResponse()
        do {
            _ = try await alice.send(Data("once".utf8))
            XCTFail("Dropped response succeeded")
        } catch {}
        let reopened = try session("alice", transport: relay)
        let pending = try await reopened.pendingDelivery()
        XCTAssertNotNil(pending)
        let flushed = try await reopened.flush()
        guard case .accepted = flushed else { return XCTFail("Retry not accepted") }
        let nothingLeft = try await reopened.flush()
        XCTAssertNil(nothingLeft)
        try await bob.synchronize()
        let inbox = try await bob.inbox()
        XCTAssertEqual(inbox.map(\.plaintext), [Data("once".utf8)])
    }

    func testStaleSenderResolvesEpochConflicts() async throws {
        let relay = FakeMLSRelay()
        let (alice, bob, group) = try await pair(relay)
        let charlie = try session("charlie", transport: relay)
        try await admit(charlie, by: alice, group: group)

        let dave = try session("dave", transport: relay)
        let token = Data(repeating: 6, count: 32)
        let published = try await dave.publishKeyPackage(pairingToken: token)
        let keyPackage = try await XCTUnwrapAsync(await bob.fetchKeyPackage(reference: published.reference, pairingToken: token))
        let staleSend = try await bob.send(Data("after conflict".utf8))
        guard case .accepted = staleSend else { return XCTFail("Stale message not resealed") }
        try await charlie.synchronize()
        let charlieInbox = try await charlie.inbox()
        XCTAssertEqual(charlieInbox.last?.plaintext, Data("after conflict".utf8))

        let removed = try await alice.remove(fingerprint: charlie.fingerprint())
        guard case .accepted = removed else { return XCTFail("Removal not accepted") }
        let staleAdd = try await bob.add(keyPackage: keyPackage, verifiedFingerprint: published.fingerprint, reference: published.reference)
        XCTAssertEqual(staleAdd, .superseded)
        let rejected = try await bob.rejectedCommit()
        XCTAssertEqual(rejected?.keyPackageReference, published.reference)
        let bobEpoch = try await bob.epoch()
        let aliceEpoch = try await alice.epoch()
        XCTAssertEqual(bobEpoch, aliceEpoch)
    }

    func testUnavailableKeyPackageUnblocksInviter() async throws {
        let relay = FakeMLSRelay()
        let alice = try session("alice", transport: relay)
        try await alice.createGroup(Data(repeating: 8, count: 32))
        let bob = try session("bob", transport: relay)
        let identity = try await bob.joiningIdentityForTesting()
        let result = try await alice.add(
            keyPackage: identity.keyPackage, verifiedFingerprint: identity.fingerprint,
            reference: Data(SHA256.hash(data: identity.keyPackage))
        )
        XCTAssertEqual(result, .superseded)
        let rejected = try await alice.rejectedCommit()
        XCTAssertNotNil(rejected)
        let message = try await alice.send(Data("not stuck".utf8))
        guard case .accepted = message else { return XCTFail("Inviter blocked") }
    }

    func testRemovedMemberStopsAndCannotSend() async throws {
        let relay = FakeMLSRelay()
        let (alice, bob, _) = try await pair(relay)
        _ = try await alice.remove(fingerprint: bob.fingerprint())
        try await bob.synchronize()
        let removed = try await bob.isRemoved()
        XCTAssertTrue(removed)
        do {
            _ = try await bob.send(Data("after removal".utf8))
            XCTFail("Removed member sent")
        } catch {}
        let members = try await alice.members()
        XCTAssertEqual(members.count, 1)
    }

    func testInvalidCommitFailsClosedWithoutAdvancingCursor() async throws {
        let relay = FakeMLSRelay()
        let (alice, bob, group) = try await pair(relay)
        let before = try await bob.cursor()
        let epoch = try await alice.epoch()
        await relay.inject(MLSDelivery(group: group, epoch: epoch, kind: .commit, payload: Data("forged".utf8)))
        do {
            try await bob.synchronize()
            XCTFail("Forged commit accepted")
        } catch {}
        let after = try await bob.cursor()
        XCTAssertEqual(after, before)
    }

    func testMLSEndpointDerivesFromMailboxOrigin() throws {
        let configuration = try SyncEndpointConfiguration(
            relayURL: XCTUnwrap(URL(string: "wss://sync.example.com/v1")),
            mailboxURL: XCTUnwrap(URL(string: "https://sync.example.com:8443/v1/mailbox")),
            policy: .production
        )
        XCTAssertEqual(configuration.mlsURL.absoluteString, "https://sync.example.com:8443/v2/mls")
        XCTAssertNoThrow(try SyncEndpointConfiguration.validateMLSURL(configuration.mlsURL, policy: .production))
        let local = try XCTUnwrap(URL(string: "http://127.0.0.1:9000/v2/mls"))
        XCTAssertThrowsError(try SyncEndpointConfiguration.validateMLSURL(local, policy: .production))
        XCTAssertNoThrow(try SyncEndpointConfiguration.validateMLSURL(local, policy: .localDevelopment))
        XCTAssertThrowsError(try SyncEndpointConfiguration.validateMLSURL(
            XCTUnwrap(URL(string: "https://sync.example.com/v1/mailbox")), policy: .production
        ))
    }

    func testHTTPTransportRefusesPlaintextProductionEndpoint() async throws {
        let transport = HTTPMLSRelayTransport(baseURL: try XCTUnwrap(URL(string: "http://sync.example.com/v2/mls")))
        do {
            try await transport.createGroup(Data(repeating: 1, count: 32), authorization: Data(repeating: 2, count: 32))
            XCTFail("Plaintext endpoint used")
        } catch { XCTAssertEqual(error as? MLSRelayError, .insecureTransport) }
    }

    func testThreeSessionsThroughRealRelay() async throws {
        guard ProcessInfo.processInfo.environment["GOTSYNC_INTEGRATION"] == "1" else {
            if ProcessInfo.processInfo.environment["GOTSYNC_REQUIRE_INTEGRATION"] == "1" {
                XCTFail("The required relay integration environment is missing.")
                return
            }
            throw XCTSkip("Run scripts/test-integration.sh to start the real relay.")
        }
        let mailboxURL = try XCTUnwrap(URL(string: ProcessInfo.processInfo.environment["GOTSYNC_MAILBOX_URL"] ?? ""))
        let relayURL = try XCTUnwrap(URL(string: ProcessInfo.processInfo.environment["GOTSYNC_RELAY_URL"] ?? ""))
        let endpoints = try SyncEndpointConfiguration(relayURL: relayURL, mailboxURL: mailboxURL, policy: .localDevelopment)
        let relay = HTTPMLSRelayTransport(baseURL: endpoints.mlsURL, policy: .localDevelopment)

        let (alice, bob, group) = try await pair(relay)
        let token = try Data.secureRandom(count: 32)
        let charlie = try session("charlie", transport: relay)
        let published = try await charlie.publishKeyPackage(pairingToken: token)
        let wrongToken = try Data.secureRandom(count: 32)
        do {
            _ = try await alice.fetchKeyPackage(reference: published.reference, pairingToken: wrongToken)
            XCTFail("Key package released for wrong pairing token")
        } catch { XCTAssertEqual(error as? MLSRelayError, .unauthorized) }
        let keyPackage = try await XCTUnwrapAsync(await alice.fetchKeyPackage(reference: published.reference, pairingToken: token))
        let consumed = try await alice.fetchKeyPackage(reference: published.reference, pairingToken: token)
        XCTAssertNil(consumed)
        let added = try await alice.add(keyPackage: keyPackage, verifiedFingerprint: published.fingerprint, reference: published.reference)
        guard case .accepted = added else { return XCTFail("Add not accepted") }
        let joined = try await charlie.join(group: group, keyPackageReference: published.reference, verifiedInviterFingerprint: alice.fingerprint())
        XCTAssertTrue(joined)

        _ = try await bob.send(Data("from Bob".utf8))
        _ = try await alice.send(Data("from Alice".utf8))
        try await charlie.synchronize()
        let charlieInbox = try await charlie.inbox()
        XCTAssertEqual(Set(charlieInbox.map(\.plaintext)), [Data("from Bob".utf8), Data("from Alice".utf8)])

        let offline = try session("bob", transport: relay)
        _ = try await alice.send(Data("while Bob was offline".utf8))
        try await offline.synchronize()
        let bobInbox = try await offline.inbox()
        XCTAssertEqual(bobInbox.last?.plaintext, Data("while Bob was offline".utf8))

        let bobAuthorization = try await offline.transportAuthorizationForTesting()
        let removal = try await alice.remove(fingerprint: offline.fingerprint())
        guard case .accepted = removal else { return XCTFail("Removal not accepted") }
        try await offline.synchronize()
        let removed = try await offline.isRemoved()
        XCTAssertTrue(removed)
        do {
            _ = try await relay.fetch(group: group, after: 0, limit: 1, authorization: bobAuthorization)
            XCTFail("Removed writer can still read")
        } catch { XCTAssertEqual(error as? MLSRelayError, .unauthorized) }

        _ = try await charlie.send(Data("after removal".utf8))
        try await alice.synchronize()
        let aliceInbox = try await alice.inbox()
        XCTAssertEqual(aliceInbox.last?.plaintext, Data("after removal".utf8))
        let members = try await alice.members()
        XCTAssertEqual(members.count, 2)
    }
}

extension MLSSession {
    func transportAuthorizationForTesting() async throws -> Data {
        try await client.transportAuthorization()
    }

    func joiningIdentityForTesting() async throws -> MLSJoiningIdentity {
        try await client.joiningIdentity()
    }
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
