import CryptoKit
import Foundation
import XCTest
import SQLite3
import GotSyncMLSBindings
@testable import GotSyncMLS

@MainActor
final class MLSClientTests: XCTestCase {
    private var root: URL!
    private var stateKeys: [UInt8: InMemoryStateKeyProvider] = [:]

    override func setUp() async throws {
        stateKeys = [:]
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try FileManager.default.removeItem(at: root) }

    private func client(_ id: UInt8) throws -> MLSClient {
        let stateKey = stateKeys[id] ?? InMemoryStateKeyProvider()
        stateKeys[id] = stateKey
        return try MLSClient(directory: root.appendingPathComponent(String(id)), deviceID: Data(repeating: id, count: 16), stateKey: stateKey)
    }

    private func storedRecord() -> ClientRecord {
        ClientRecord(
            state: Data("stored MLS state".utf8), deviceID: Data("private-device-identifier".utf8),
            identity: IdentityRecord(fingerprint: Data("private-identity-fingerprint".utf8)),
            writerToken: Data(repeating: 9, count: 32)
        )
    }

    private func rewriteStoredBlob(_ transform: (inout Data) -> Void) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("mls-v2.sqlite3").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT record FROM client WHERE id=1", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let pointer = try XCTUnwrap(sqlite3_column_blob(statement, 0))
        var blob = Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0)))
        transform(&blob)
        XCTAssertEqual(sqlite3_exec(database, "UPDATE client SET record=X'\(blob.map { String(format: "%02x", $0) }.joined())' WHERE id=1", nil, nil, nil), SQLITE_OK)
    }

    func testEncryptedStoreReopenRoundTrip() throws {
        let stateKey = InMemoryStateKeyProvider()
        let record = storedRecord()
        do {
            let store = try MLSStore(directory: root, stateKey: stateKey)
            try store.update { $0 = record }
        }
        let reopened = try MLSStore(directory: root, stateKey: stateKey)
        let recovered = try reopened.read()
        XCTAssertEqual(recovered.state, record.state)
        XCTAssertEqual(recovered.deviceID, record.deviceID)
        XCTAssertEqual(recovered.identity.fingerprint, record.identity.fingerprint)
        XCTAssertEqual(recovered.writerToken, record.writerToken)
    }

    func testEncryptedStoreRejectsModifiedCiphertext() throws {
        let store = try MLSStore(directory: root, stateKey: InMemoryStateKeyProvider())
        try store.update { $0 = storedRecord() }
        try rewriteStoredBlob { $0[$0.count / 2] ^= 1 }
        XCTAssertThrowsError(try store.read()) { error in
            XCTAssertEqual(error as? MLSStoreError, .unreadable)
        }
    }

    func testEncryptedStoreRejectsDifferentKey() throws {
        do {
            let store = try MLSStore(directory: root, stateKey: InMemoryStateKeyProvider())
            try store.update { $0 = storedRecord() }
        }
        let reopened = try MLSStore(directory: root, stateKey: InMemoryStateKeyProvider())
        XCTAssertThrowsError(try reopened.read()) { error in
            XCTAssertEqual(error as? MLSStoreError, .unreadable)
        }
        XCTAssertThrowsError(try MLSClient(directory: root, deviceID: storedRecord().deviceID, stateKey: InMemoryStateKeyProvider())) { error in
            XCTAssertEqual(error as? MLSStoreError, .unreadable)
        }
    }

    func testEncryptedStorePreservesRecordAfterKeyProviderFailure() throws {
        struct UnavailableStateKeyProvider: MLSStateKeyProvider {
            func key() throws -> SymmetricKey { throw MLSClientError.storageUnavailable }
        }
        let stateKey = InMemoryStateKeyProvider()
        let record = storedRecord()
        do {
            let store = try MLSStore(directory: root, stateKey: stateKey)
            try store.update { $0 = record }
        }
        XCTAssertThrowsError(try MLSStore(directory: root, stateKey: UnavailableStateKeyProvider())) { error in
            guard case MLSClientError.storageUnavailable = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let reopened = try MLSStore(directory: root, stateKey: stateKey)
        XCTAssertEqual(try reopened.read().state, record.state)
        XCTAssertEqual(try reopened.read().deviceID, record.deviceID)
    }

    func testEncryptedStoreRejectsInvalidProviderKeySize() throws {
        let stateKey = InMemoryStateKeyProvider(key: SymmetricKey(size: .bits128))
        XCTAssertThrowsError(try MLSStore(directory: root, stateKey: stateKey)) { error in
            guard case MLSClientError.storageUnavailable = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testEncryptedStoreReportsAuthenticatedDecodeFailureAsStorageUnavailable() throws {
        let stateKey = InMemoryStateKeyProvider()
        let store = try MLSStore(directory: root, stateKey: stateKey)
        try store.update { $0 = storedRecord() }
        let version = Data([1])
        let combined = try XCTUnwrap(AES.GCM.seal(Data("not a record".utf8), using: stateKey.key(), authenticating: version).combined)
        try rewriteStoredBlob { $0 = version + combined }
        XCTAssertThrowsError(try store.read()) { error in
            guard case MLSClientError.storageUnavailable = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testEncryptedStoreCapsCiphertextAndPreservesPreviousRecord() throws {
        let store = try MLSStore(directory: root, stateKey: InMemoryStateKeyProvider())
        let original = storedRecord()
        try store.update { $0 = original }
        var oversized = original
        oversized.state = Data()
        let overhead = try JSONEncoder().encode(oversized).count
        oversized.state = Data(repeating: 0, count: ((32 * 1024 * 1024 - overhead) / 4) * 3)
        let plaintextCount = try JSONEncoder().encode(oversized).count
        XCTAssertLessThanOrEqual(plaintextCount, 32 * 1024 * 1024)
        XCTAssertGreaterThan(plaintextCount + 29, 32 * 1024 * 1024)
        XCTAssertThrowsError(try store.update { $0 = oversized }) { error in
            guard case MLSClientError.capacityReached = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try store.read().state, original.state)
    }

    func testEncryptedStoreHidesIdentityInSQLiteFile() throws {
        let record = storedRecord()
        do {
            let store = try MLSStore(directory: root, stateKey: InMemoryStateKeyProvider())
            try store.update { $0 = record }
        }
        let bytes = try Data(contentsOf: root.appendingPathComponent("mls-v2.sqlite3"))
        for secret in [record.deviceID, record.identity.fingerprint] {
            XCTAssertNil(bytes.range(of: secret))
            XCTAssertNil(bytes.range(of: Data(secret.base64EncodedString().utf8)))
        }
    }

    func testEncryptedStoreRejectsUnknownVersion() throws {
        let store = try MLSStore(directory: root, stateKey: InMemoryStateKeyProvider())
        try store.update { $0 = storedRecord() }
        try rewriteStoredBlob { $0[0] ^= 1 }
        XCTAssertThrowsError(try store.read()) { error in
            XCTAssertEqual(error as? MLSStoreError, .unreadable)
        }
    }

    func testJoiningIdentityRefreshesPackageAndPersistsPrivateState() async throws {
        let alice = try client(1)
        let bob = try client(2)
        let first = try await bob.joiningIdentity()
        let fresh = try await bob.joiningIdentity()
        XCTAssertNotEqual(first.keyPackage, fresh.keyPackage)
        XCTAssertEqual(first.fingerprint, fresh.fingerprint)
        let group = Data(repeating: 7, count: 32)
        try await alice.createGroup(id: group)
        let old = try await alice.prepareAdd(keyPackage: first.keyPackage, verifiedFingerprint: first.fingerprint, reference: Data(SHA256.hash(data: first.keyPackage)))
        let reopened = try client(2)
        try await alice.process(old, cursor: 1)
        try await reopened.join(welcome: XCTUnwrap(old.welcome), group: group, verifiedInviterFingerprint: alice.fingerprint(), cursor: 1)
        let message = try await alice.prepareMessage(Data("paired using first package".utf8))
        try await reopened.process(message, cursor: 2)
        let inbox = try await reopened.inbox()
        XCTAssertEqual(inbox.last?.plaintext, Data("paired using first package".utf8))
    }

    func testPendingCommitAndInboxSurviveReopening() async throws {
        let alice = try client(1)
        let bob = try client(2)
        let group = Data(repeating: 7, count: 32)
        let joining = try await bob.joiningIdentity()
        try await alice.createGroup(id: group)
        let pending = try await alice.prepareAdd(keyPackage: joining.keyPackage, verifiedFingerprint: joining.fingerprint, reference: Data(SHA256.hash(data: joining.keyPackage)))
        let reopenedAlice = try client(1)
        let recovered = try await reopenedAlice.pendingDelivery()
        XCTAssertEqual(recovered, pending)
        try await reopenedAlice.process(pending, cursor: 1)
        try await bob.join(welcome: XCTUnwrap(pending.welcome), group: group, verifiedInviterFingerprint: alice.fingerprint(), cursor: 1)
        let message = try await reopenedAlice.prepareMessage(Data("durable inbox".utf8))
        try await bob.process(message, cursor: 2)
        let reopenedBob = try client(2)
        let inbox = try await reopenedBob.inbox()
        XCTAssertEqual(inbox.map(\.plaintext), [Data("durable inbox".utf8)])
        try await reopenedBob.process(message, cursor: 2)
        let afterReplay = try await reopenedBob.inbox()
        XCTAssertEqual(afterReplay, inbox)
        try await reopenedBob.acknowledgeInbox(through: 2)
        let empty = try await client(2).inbox()
        XCTAssertTrue(empty.isEmpty)
    }

    func testStorageFailureRollsBackEntireTransition() async throws {
        let alice = try client(1)
        try await alice.createGroup(id: Data(repeating: 7, count: 32))
        let store = try MLSStore(directory: root.appendingPathComponent("1"), stateKey: try XCTUnwrap(stateKeys[1]))
        let before = try store.read().state
        enum Injected: Error { case failure }
        XCTAssertThrowsError(try store.update { record in
            record!.state = Data("discarded mutation".utf8)
            throw Injected.failure
        })
        XCTAssertEqual(try store.read().state, before)
        XCTAssertNil(try store.read().pending)
    }

    func testWrongFingerprintDoesNotChangePersistedState() async throws {
        let alice = try client(1)
        let bob = try client(2)
        try await alice.createGroup(id: Data(repeating: 7, count: 32))
        let identity = try await bob.joiningIdentity()
        do {
            _ = try await alice.prepareAdd(keyPackage: identity.keyPackage, verifiedFingerprint: Data(repeating: 0, count: 32), reference: Data(SHA256.hash(data: identity.keyPackage)))
            XCTFail("Unverified identity accepted")
        } catch {}
        let pending = try await alice.pendingDelivery()
        let epoch = try await alice.epoch()
        XCTAssertNil(pending)
        XCTAssertEqual(epoch, 0)
        _ = try await alice.prepareAdd(keyPackage: identity.keyPackage, verifiedFingerprint: identity.fingerprint, reference: Data(SHA256.hash(data: identity.keyPackage)))
    }

    func testThreeSwiftClientsAgainstRealRelay() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["GOTSYNC_MLS_URL"], let url = URL(string: endpoint) else {
            throw XCTSkip("Run scripts/test-mls.sh for the real relay test")
        }
        let alice = try client(1)
        let relay = SpikeRelay(url: url, authorization: try await alice.transportAuthorization())
        let bob = try client(2)
        let charlie = try client(3)
        let group = UUID().uuidString.data(using: .utf8)!.prefix(32)
        try await alice.createGroup(id: group)
        _ = try await relay.post("create", ["group": group.b64], authorization: alice.transportAuthorization())
        let unpublished = try await bob.joiningIdentity()
        let refusedAdd = try await alice.prepareAdd(keyPackage: unpublished.keyPackage, verifiedFingerprint: unpublished.fingerprint, reference: Data(SHA256.hash(data: unpublished.keyPackage)))
        do {
            _ = try await relay.append(refusedAdd)
            XCTFail("Unpublished KeyPackage accepted")
        } catch let error as SpikeRelay.Error {
            XCTAssertEqual(error.status, 409)
            XCTAssertEqual(error.code, "keyPackageUnavailable")
            try await alice.rejectAddForUnavailableKeyPackage(commit: refusedAdd.payload, rejectedEpoch: XCTUnwrap(error.epoch))
        }

        func add(_ joining: MLSClient, observers: [MLSClient]) async throws {
            let identity = try await joining.joiningIdentity()
            let pairingToken = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            let reference = try await relay.publish(identity.keyPackage, writer: joining.transportAuthorization(), pairingToken: pairingToken)
            let fetched = try await relay.keyPackage(reference, pairingToken: pairingToken)
            XCTAssertEqual(fetched, identity.keyPackage)
            let consumed = try await relay.post("key-package/fetch", ["reference": reference.b64, "pairingToken": pairingToken.b64])
            XCTAssertTrue(consumed["payload"] is NSNull)
            let pending = try await alice.prepareAdd(keyPackage: fetched, verifiedFingerprint: identity.fingerprint, reference: reference)
            let cursor = try await relay.append(pending)
            let retryCursor = try await relay.append(pending)
            XCTAssertEqual(cursor, retryCursor)
            let reopened = try client(1)
            let recovered = try await reopened.pendingDelivery()
            XCTAssertEqual(recovered, pending)
            try await catchUp(reopened, group: group, relay: relay)
            for observer in observers { try await catchUp(observer, group: group, relay: relay) }
            try await joining.join(welcome: XCTUnwrap(pending.welcome), group: group, verifiedInviterFingerprint: alice.fingerprint(), cursor: cursor)
            try await relay.ack(group: group, cursor: cursor, authorization: joining.transportAuthorization())
        }

        try await add(bob, observers: [])
        try await add(charlie, observers: [bob])
        let fromAlice = try await alice.prepareMessage(Data("from Alice".utf8))
        let fromBob = try await bob.prepareMessage(Data("from Bob".utf8))
        _ = try await relay.append(fromAlice)
        _ = try await relay.append(fromBob, authorization: bob.transportAuthorization())
        try await catchUp(alice, group: group, relay: relay)
        try await catchUp(bob, group: group, relay: relay)
        try await catchUp(charlie, group: group, relay: relay)
        let aliceInbox = try await alice.inbox()
        XCTAssertEqual(aliceInbox.last?.plaintext, Data("from Bob".utf8))

        let message = try await alice.prepareMessage(Data("offline edit".utf8))
        _ = try await relay.append(message)
        try await catchUp(alice, group: group, relay: relay)
        try await catchUp(charlie, group: group, relay: relay)
        let reopenedBob = try client(2)
        try await catchUp(reopenedBob, group: group, relay: relay)
        let bobInbox = try await reopenedBob.inbox()
        XCTAssertEqual(bobInbox.last?.plaintext, Data("offline edit".utf8))

        let compromisedDirectory = root.appendingPathComponent("compromised")
        try FileManager.default.copyItem(at: root.appendingPathComponent("2"), to: compromisedDirectory)
        let compromised = try MLSClient(directory: compromisedDirectory, deviceID: Data(repeating: 2, count: 16), stateKey: try XCTUnwrap(stateKeys[2]))
        let pending = try await alice.prepareRemove(fingerprint: bob.fingerprint())
        let competing = try await charlie.prepareRemove(fingerprint: bob.fingerprint())
        let bobWriter = try await alice.members().first { $0.deviceID == Data(repeating: 2, count: 16) }
        XCTAssertEqual(pending.removeWriter, try XCTUnwrap(bobWriter).writerHash)
        _ = try await relay.append(pending)
        do {
            _ = try await relay.append(competing, authorization: charlie.transportAuthorization())
            XCTFail("Relay accepted two commits at one epoch")
        } catch let error as SpikeRelay.Error { XCTAssertEqual(error.status, 409) }
        try await catchUp(alice, group: group, relay: relay)
        try await catchUp(charlie, group: group, relay: relay)
        try await catchUp(reopenedBob, group: group, relay: relay)
        let removed = try await reopenedBob.isRemoved()
        XCTAssertTrue(removed)
        do {
            _ = try await relay.fetch(group: group, after: 0, authorization: compromised.transportAuthorization())
            XCTFail("Relay allowed reads after removal acknowledgement")
        } catch let error as SpikeRelay.Error { XCTAssertEqual(error.status, 403) }
        let afterRemoval = try await alice.prepareMessage(Data("new epoch".utf8))
        let cursor = try await relay.append(afterRemoval)
        try await catchUp(charlie, group: group, relay: relay)
        let charlieInbox = try await charlie.inbox()
        XCTAssertEqual(charlieInbox.last?.plaintext, Data("new epoch".utf8))
        do {
            try await compromised.process(afterRemoval, cursor: cursor)
            XCTFail("Skipped removal epoch accepted")
        } catch {}
        let compromisedInbox = try await compromised.inbox()
        XCTAssertFalse(compromisedInbox.contains { $0.plaintext == Data("new epoch".utf8) })
        let stale = try await compromised.prepareRemove(fingerprint: charlie.fingerprint())
        do {
            _ = try await relay.append(stale, authorization: compromised.transportAuthorization())
            XCTFail("Relay accepted stale commit")
        } catch let error as SpikeRelay.Error { XCTAssertEqual(error.status, 403) }
    }

    private func paired() async throws -> (MLSClient, MLSClient, Data) {
        let alice = try client(1)
        let bob = try client(2)
        let group = Data(repeating: 7, count: 32)
        try await alice.createGroup(id: group)
        let identity = try await bob.joiningIdentity()
        let pending = try await alice.prepareAdd(keyPackage: identity.keyPackage, verifiedFingerprint: identity.fingerprint, reference: Data(SHA256.hash(data: identity.keyPackage)))
        try await alice.process(pending, cursor: 1)
        try await bob.join(welcome: XCTUnwrap(pending.welcome), group: group, verifiedInviterFingerprint: alice.fingerprint(), cursor: 1)
        return (alice, bob, group)
    }

    func testApplicationBeforeOwnCommitDoesNotBlockCatchup() async throws {
        let (alice, bob, _) = try await paired()
        let message = try await bob.prepareMessage(Data("before commit".utf8))
        let pending = try await alice.prepareRemove(fingerprint: bob.fingerprint())
        try await alice.process(message, cursor: 2)
        try await alice.process(pending, cursor: 3)
        let inbox = try await alice.inbox()
        XCTAssertEqual(inbox.last?.plaintext, Data("before commit".utf8))
        let sender = try await bob.fingerprint()
        XCTAssertEqual(inbox.last?.sender, sender)
        let remaining = try await alice.pendingDelivery()
        XCTAssertNil(remaining)
    }

    func testStaleApplicationIsDurablyResealedAfterWinningCommit() async throws {
        let (alice, bob, group) = try await paired()
        let charlie = try client(3)
        let identity = try await charlie.joiningIdentity()
        let oldMessage = try await bob.prepareMessage(Data("retry after epoch change".utf8))
        let commit = try await alice.prepareAdd(keyPackage: identity.keyPackage, verifiedFingerprint: identity.fingerprint, reference: Data(SHA256.hash(data: identity.keyPackage)))
        try await alice.process(commit, cursor: 2)
        try await bob.process(commit, cursor: 2)
        let recoveredBob = try client(2)
        let recovered = try await recoveredBob.pendingDelivery()
        let retry = try XCTUnwrap(recovered)
        XCTAssertEqual(retry.epoch, 2)
        XCTAssertNotEqual(retry.payload, oldMessage.payload)
        try await alice.process(retry, cursor: 3)
        try await recoveredBob.process(retry, cursor: 3)
        try await charlie.join(welcome: XCTUnwrap(commit.welcome), group: group, verifiedInviterFingerprint: alice.fingerprint(), cursor: 2)
        try await charlie.process(retry, cursor: 3)
        let inbox = try await charlie.inbox()
        XCTAssertEqual(inbox.last?.plaintext, Data("retry after epoch change".utf8))
    }

    func testLosingCommitIsRecordedAndWinnerConverges() async throws {
        let (alice, bob, _) = try await paired()
        let charlie = try await client(3).joiningIdentity()
        let dave = try await client(4).joiningIdentity()
        let winner = try await alice.prepareAdd(keyPackage: charlie.keyPackage, verifiedFingerprint: charlie.fingerprint, reference: Data(SHA256.hash(data: charlie.keyPackage)))
        let loser = try await bob.prepareAdd(keyPackage: dave.keyPackage, verifiedFingerprint: dave.fingerprint, reference: Data(SHA256.hash(data: dave.keyPackage)))
        try await alice.process(winner, cursor: 2)
        try await bob.process(winner, cursor: 2)
        let rejected = try await bob.rejectedCommit()
        XCTAssertEqual(rejected, loser)
        let message = try await bob.prepareMessage(Data("converged".utf8))
        try await alice.process(message, cursor: 3)
        let inbox = try await alice.inbox()
        XCTAssertEqual(inbox.last?.plaintext, Data("converged".utf8))
    }

    func testInvalidApplicationIsSkippedAndInvalidCommitFailsClosed() async throws {
        let (alice, bob, group) = try await paired()
        let bad = MLSDelivery(group: group, epoch: 1, kind: .application, payload: Data("garbage".utf8))
        try await alice.process(bad, cursor: 2)
        let rejected = try await alice.rejectedApplicationCursors()
        XCTAssertEqual(rejected, [2])
        let badCommit = MLSDelivery(group: group, epoch: 1, kind: .commit, payload: Data("garbage".utf8))
        do { try await alice.process(badCommit, cursor: 3); XCTFail("Invalid commit accepted") } catch {}
        let cursor = try await alice.cursor()
        XCTAssertEqual(cursor, 2)
        let message = try await bob.prepareMessage(Data("after garbage".utf8))
        try await alice.process(message, cursor: 4)
        let inbox = try await alice.inbox()
        XCTAssertEqual(inbox.last?.plaintext, Data("after garbage".utf8))
    }

    func testDecryptionBeforeStorageFailureCanBeRetried() async throws {
        let (alice, bob, _) = try await paired()
        let message = try await bob.prepareMessage(Data("survives failure".utf8))
        let store = try MLSStore(directory: root.appendingPathComponent("1"), stateKey: try XCTUnwrap(stateKeys[1]))
        let before = try store.read().state
        enum Injected: Error { case failure }
        XCTAssertThrowsError(try store.update { record in
            let transition = try receiveMessage(state: record!.state, message: message.payload)
            record!.state = transition.state
            record!.inbox.append(MLSInboxMessage(cursor: 2, sender: transition.sender!, plaintext: transition.output))
            throw Injected.failure
        })
        XCTAssertEqual(try store.read().state, before)
        XCTAssertTrue(try store.read().inbox.isEmpty)
        try await alice.process(message, cursor: 2)
        let inbox = try await alice.inbox()
        XCTAssertEqual(inbox.last?.plaintext, Data("survives failure".utf8))
    }

    func testRelabeledCommitAndEpochGapFailWithoutAdvancingCursor() async throws {
        let (alice, bob, group) = try await paired()
        let commit = try await alice.prepareRemove(fingerprint: bob.fingerprint())
        let relabeled = MLSDelivery(group: group, epoch: commit.epoch, kind: .application, payload: commit.payload)
        do { try await bob.process(relabeled, cursor: 2); XCTFail("Relabeled commit accepted") } catch {}
        let cursor = try await bob.cursor()
        XCTAssertEqual(cursor, 1)
        let future = MLSDelivery(group: group, epoch: 2, kind: .application, payload: Data("opaque".utf8))
        do { try await bob.process(future, cursor: 3); XCTFail("Skipped epoch accepted") } catch {}
        let afterGap = try await bob.cursor()
        XCTAssertEqual(afterGap, 1)
        try await bob.process(commit, cursor: 2)
        let removed = try await bob.isRemoved()
        XCTAssertTrue(removed)
    }

    func testTerminalKeyPackageRejectionUnblocksInviter() async throws {
        let alice = try client(1)
        let bob = try await client(2).joiningIdentity()
        try await alice.createGroup(id: Data(repeating: 7, count: 32))
        let pending = try await alice.prepareAdd(keyPackage: bob.keyPackage, verifiedFingerprint: bob.fingerprint, reference: Data(SHA256.hash(data: bob.keyPackage)))
        do {
            try await alice.rejectAddForUnavailableKeyPackage(commit: pending.payload, rejectedEpoch: 1)
            XCTFail("Incorrect rejection epoch accepted")
        } catch {}
        try await alice.rejectAddForUnavailableKeyPackage(commit: pending.payload, rejectedEpoch: 0)
        let rejected = try await alice.rejectedCommit()
        XCTAssertEqual(rejected, pending)
        _ = try await alice.prepareMessage(Data("not stuck".utf8))
    }

    private func catchUp(_ client: MLSClient, group: Data, relay: SpikeRelay) async throws {
        let authorization = try await client.transportAuthorization()
        for _ in 0..<100 {
            let entries = try await relay.fetch(group: group, after: client.cursor(), authorization: authorization)
            guard !entries.isEmpty else { return }
            for (delivery, cursor) in entries {
                try await client.process(delivery, cursor: cursor)
                try await relay.ack(group: group, cursor: cursor, authorization: authorization)
                if try await client.isRemoved() { return }
            }
        }
        XCTFail("Unexpected log length")
    }
}

@MainActor
private struct SpikeRelay {
    struct Error: Swift.Error {
        let status: Int
        let code: String?
        let epoch: UInt64?
    }
    let url: URL
    let authorization: Data

    func post(_ operation: String, _ values: [String: Any], authorization: Data? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: url.appendingPathComponent(operation))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization { request.setValue("Bearer \(authorization.b64)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: values.merging(["version": 2]) { _, new in new })
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as! HTTPURLResponse).statusCode
        let document = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        guard status == 200 else { throw Error(status: status, code: document["error"] as? String, epoch: document["epoch"] as? UInt64) }
        return document
    }
    func publish(_ payload: Data, writer: Data, pairingToken: Data) async throws -> Data {
        try await decode(post("key-package/publish", ["payload": payload.b64, "pairingHash": Data(SHA256.hash(data: pairingToken)).b64], authorization: writer)["reference"])
    }
    func keyPackage(_ reference: Data, pairingToken: Data) async throws -> Data {
        try await decode(post("key-package/fetch", ["reference": reference.b64, "pairingToken": pairingToken.b64])["payload"])
    }
    func append(_ delivery: MLSDelivery, authorization: Data? = nil) async throws -> UInt64 {
        var values: [String: Any] = ["group": delivery.group.b64, "epoch": delivery.epoch, "kind": delivery.kind.rawValue, "payload": delivery.payload.b64]
        values["welcome"] = delivery.welcome?.b64
        values["reference"] = delivery.keyPackageReference?.b64
        values["removeWriter"] = delivery.removeWriter?.b64
        values["addWriter"] = delivery.addWriter?.b64
        let response = try await post("append", values, authorization: authorization ?? self.authorization)
        return (response["entry"] as! [String: Any])["cursor"] as! UInt64
    }
    func ack(group: Data, cursor: UInt64, authorization: Data) async throws {
        _ = try await post("ack", ["route": group.b64, "cursor": cursor], authorization: authorization)
    }
    func fetch(group: Data, after: UInt64, authorization: Data) async throws -> [(MLSDelivery, UInt64)] {
        let response = try await post("fetch", ["group": group.b64, "after": after], authorization: authorization)
        return try (response["entries"] as! [[String: Any]]).map { entry in
            let delivery = MLSDelivery(group: group, epoch: entry["epoch"] as! UInt64, kind: MLSDelivery.Kind(rawValue: entry["kind"] as! String)!, payload: try decode(entry["payload"]), welcome: try optional(entry["welcome"]), keyPackageReference: try optional(entry["reference"]), addWriter: try optional(entry["addWriter"]), removeWriter: try optional(entry["removeWriter"]))
            return (delivery, entry["cursor"] as! UInt64)
        }
    }
    func decode(_ value: Any?) throws -> Data {
        let text = try XCTUnwrap(value as? String)
        let standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return try XCTUnwrap(Data(base64Encoded: standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)))
    }
    func optional(_ value: Any?) throws -> Data? { value is String ? try decode(value) : nil }
}

private extension Data {
    var b64: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
