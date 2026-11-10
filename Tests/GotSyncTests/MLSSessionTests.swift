import CryptoKit
import Foundation
import GotSyncMLS
import XCTest
@_spi(HostJournalPreview) @testable import GotSync

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
        try await alice.createGroup(group, profile: nil)
        try await admit(bob, by: alice, group: group)
        return (alice, bob, group)
    }

    private func realRelay() throws -> HTTPMLSRelayTransport? {
        guard ProcessInfo.processInfo.environment["GOTSYNC_INTEGRATION"] == "1" else {
            if ProcessInfo.processInfo.environment["GOTSYNC_REQUIRE_INTEGRATION"] == "1" {
                XCTFail("The required relay integration environment is missing.")
                return nil
            }
            throw XCTSkip("Run scripts/test-integration.sh to start the real relay.")
        }
        let mailboxURL = try XCTUnwrap(URL(string: ProcessInfo.processInfo.environment["GOTSYNC_MAILBOX_URL"] ?? ""))
        let relayURL = try XCTUnwrap(URL(string: ProcessInfo.processInfo.environment["GOTSYNC_RELAY_URL"] ?? ""))
        let endpoints = try SyncEndpointConfiguration(relayURL: relayURL, mailboxURL: mailboxURL, policy: .localDevelopment)
        return HTTPMLSRelayTransport(baseURL: endpoints.mailboxURL, policy: .localDevelopment)
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
        try await alice.createGroup(group, profile: nil)
        let published = try await bob.publishKeyPackage(pairingToken: Data(repeating: 3, count: 32), profile: nil)
        let joined = try await bob.join(group: group, keyPackageReference: published.reference, verifiedInviterFingerprint: alice.fingerprint(), profile: nil)
        XCTAssertFalse(joined)
        let bobGroup = try await bob.group()
        XCTAssertNil(bobGroup)
    }

    func testCreateGroupIsIdempotentAndRejectsSecondGroup() async throws {
        let relay = FakeMLSRelay()
        let alice = try session("alice", transport: relay)
        let group = Data(repeating: 4, count: 32)
        try await alice.createGroup(group, profile: nil)
        try await alice.createGroup(group, profile: nil)
        do {
            try await alice.createGroup(Data(repeating: 5, count: 32), profile: nil)
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

    func testTrackedMessageCursorOutlivesLaterMessages() async throws {
        let relay = FakeMLSRelay()
        let (alice, _, _) = try await pair(relay)
        await relay.dropNextAppendResponse()
        do {
            _ = try await alice.send(Data("claim".utf8), tracked: true)
            XCTFail("Dropped response succeeded")
        } catch {}
        let reopened = try session("alice", transport: relay)
        guard case .accepted(let cursor) = try await reopened.flush() else { return XCTFail("Retry not accepted") }
        for index in 0..<(MLSSentMessage.retained + 6) {
            _ = try await reopened.send(Data("edit \(index)".utf8))
        }
        let claim = try await reopened.sentCursors(of: Data("claim".utf8))
        XCTAssertEqual(claim, [cursor])
        let edit = try await reopened.sentCursors(of: Data("edit 0".utf8))
        XCTAssertEqual(edit, [])
    }

    func testTrackedMessageAcceptedBehindFullInboxKeepsItsCursor() async throws {
        let relay = FakeMLSRelay()
        let (alice, bob, _) = try await pair(relay)
        for index in 0...1_000 {
            _ = try await bob.send(Data("edit \(index)".utf8))
        }
        do {
            _ = try await alice.synchronize()
            XCTFail("A full inbox accepted more messages")
        } catch MLSClientError.capacityReached {}
        let held = try await alice.inbox()
        XCTAssertEqual(held.count, 1_000)

        let claim = try ReplicationMessage.reservation(member: Data(repeating: 7, count: 32), origins: [], epoch: 1).encoded()
        let before = try await alice.cursor()
        await relay.dropNextAppendResponse()
        do {
            _ = try await alice.send(claim, tracked: true)
            XCTFail("Dropped response succeeded")
        } catch {}
        var reopened = try session("alice", transport: relay)
        guard case .accepted(let cursor) = try await reopened.flush() else { return XCTFail("Retry not accepted") }
        let cleared = try await reopened.pendingDelivery()
        XCTAssertNil(cleared)

        reopened = try session("alice", transport: relay)
        for index in 0..<(MLSSentMessage.retained + 6) {
            guard case .accepted = try await reopened.send(Data("untracked \(index)".utf8)) else {
                return XCTFail("Untracked message not accepted")
            }
        }
        let landed = try await reopened.sentCursors(of: claim)
        XCTAssertEqual(landed, [cursor])
        XCTAssertTrue(landed.contains { $0 > before })
        let unchanged = try await reopened.inbox()
        XCTAssertEqual(unchanged, held)

        try await reopened.acknowledgeInbox(through: try XCTUnwrap(held.last).cursor)
        _ = try await reopened.synchronize()
        let rest = try await reopened.inbox()
        XCTAssertEqual(rest.map(\.plaintext), [Data("edit 1000".utf8)])
        let afterDrain = try await reopened.sentCursors(of: claim)
        XCTAssertEqual(afterDrain, [cursor])
    }

    private func publishedPackage(
        of joiner: MLSSession, for inviter: MLSSession
    ) async throws -> (keyPackage: Data, published: MLSPublishedKeyPackage) {
        let token = try Data.secureRandom(count: 32)
        let published = try await joiner.publishKeyPackage(pairingToken: token, profile: nil)
        let keyPackage = try await XCTUnwrapAsync(await inviter.fetchKeyPackage(reference: published.reference, pairingToken: token))
        return (keyPackage, published)
    }

    private func assertConverged(
        _ sessions: [MLSSession], relay: FakeMLSRelay, group: Data, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        for session in sessions { try await session.synchronize() }
        var epochs: Set<UInt64> = []
        var rosters: Set<[Data]> = []
        for session in sessions {
            epochs.insert(try await session.epoch())
            let members = try await session.members()
            XCTAssertEqual(Set(members.map(\.fingerprint)).count, members.count, "duplicate leaf", file: file, line: line)
            rosters.insert(members.map(\.fingerprint).sorted { $0.lexicographicallyPrecedes($1) })
        }
        XCTAssertEqual(epochs.count, 1, "members are in different epochs", file: file, line: line)
        XCTAssertEqual(rosters.count, 1, "members disagree on the roster", file: file, line: line)
        XCTAssertEqual(rosters.first?.count, sessions.count, "ghost or missing leaf", file: file, line: line)
        let writers = await relay.activeWriterCount(group: group)
        XCTAssertEqual(writers, sessions.count, "relay writers differ from the roster", file: file, line: line)
        for (index, sender) in sessions.enumerated() {
            let text = Data("after Add from \(index)".utf8)
            guard case .accepted = try await sender.send(text) else { return XCTFail("send refused", file: file, line: line) }
            for receiver in sessions where receiver !== sender {
                try await receiver.synchronize()
                let inbox = try await receiver.inbox()
                XCTAssertEqual(inbox.last?.plaintext, text, file: file, line: line)
            }
        }
    }

    private func addEntries(of reference: Data, relay: FakeMLSRelay, group: Data) async -> Int {
        await relay.log(group: group).filter { $0.delivery.keyPackageReference == reference }.count
    }

    func testLostAddResponseThenRateLimitedRetryRecoversTheAcceptedAddAcrossRestart() async throws {
        let relay = FakeMLSRelay()
        let (alice, bob, group) = try await pair(relay)
        let charlie = try session("charlie", transport: relay)
        let (keyPackage, published) = try await publishedPackage(of: charlie, for: alice)
        await relay.dropNextAppendResponse()
        do {
            _ = try await alice.add(keyPackage: keyPackage, verifiedFingerprint: published.fingerprint, reference: published.reference)
            XCTFail("The response should be lost")
        } catch is URLError {}
        let joined = try await charlie.join(
            group: group, keyPackageReference: published.reference, verifiedInviterFingerprint: alice.fingerprint(), profile: nil
        )
        XCTAssertTrue(joined)
        await relay.rateLimitNext(adds: 1)
        do {
            _ = try await alice.flush()
            XCTFail("The retry should be rate limited before deduplication")
        } catch MLSRelayError.rateLimited {}
        let retained = try await alice.pendingDelivery()
        XCTAssertEqual(retained?.keyPackageReference, published.reference, "an Add with an unknown outcome was discarded")

        let restarted = try session("alice", transport: relay)
        guard case .accepted = try await restarted.flush() else { return XCTFail("The accepted Add was not applied") }
        let cleared = try await restarted.pendingDelivery()
        XCTAssertNil(cleared)
        let copies = await addEntries(of: published.reference, relay: relay, group: group)
        XCTAssertEqual(copies, 1)
        try await assertConverged([restarted, bob, charlie], relay: relay, group: group)
    }

    /// The first request for an Add is held before the delivery store while
    /// the inviter sees a lost connection. Reading an empty log must not end
    /// it: the held request can still arrive, before or after the retry.
    private func assertDelayedAddIsDelivered(originalFirst: Bool, restart: Bool) async throws {
        let relay = FakeMLSRelay()
        var (alice, bob, group) = try await pair(relay)
        let charlie = try session("charlie", transport: relay)
        let (keyPackage, published) = try await publishedPackage(of: charlie, for: alice)
        await relay.deferNextAddBeforeStore()
        do {
            _ = try await alice.add(keyPackage: keyPackage, verifiedFingerprint: published.fingerprint, reference: published.reference)
            XCTFail("The ambiguous request should fail")
        } catch is URLError {}
        try await bob.synchronize()
        let empty = await addEntries(of: published.reference, relay: relay, group: group)
        XCTAssertEqual(empty, 0)
        if restart {
            alice = try session("alice", transport: relay)
        }
        if originalFirst {
            try await relay.releaseDeferredAdd()
        }
        guard case .accepted = try await alice.flush() else { return XCTFail("The Add was not delivered") }
        if !originalFirst {
            try await relay.releaseDeferredAdd()
        }
        let copies = await addEntries(of: published.reference, relay: relay, group: group)
        XCTAssertEqual(copies, 1, "the held request and the retry were both admitted")
        let joined = try await charlie.join(
            group: group, keyPackageReference: published.reference, verifiedInviterFingerprint: alice.fingerprint(), profile: nil
        )
        XCTAssertTrue(joined)
        try await assertConverged([alice, bob, charlie], relay: relay, group: group)
    }

    func testDelayedUnknownAddCannotBeAbandonedFromAnEmptyLog() async throws {
        try await assertDelayedAddIsDelivered(originalFirst: false, restart: false)
    }

    func testDelayedUnknownAddArrivingBeforeTheRetryIsDeduplicated() async throws {
        try await assertDelayedAddIsDelivered(originalFirst: true, restart: false)
    }

    func testDelayedUnknownAddSurvivesRestartBeforeTheRetry() async throws {
        try await assertDelayedAddIsDelivered(originalFirst: false, restart: true)
    }

    func testDelayedUnknownAddArrivingDuringRestartIsDeduplicated() async throws {
        try await assertDelayedAddIsDelivered(originalFirst: true, restart: true)
    }

    /// Reads the log to its head, acknowledging a full inbox on the way.
    private func drain(_ session: MLSSession) async throws {
        while true {
            do {
                try await session.synchronize()
                return
            } catch MLSClientError.capacityReached {
                try await session.acknowledgeInbox(through: try await session.cursor())
            }
        }
    }

    /// Alice's Add of Charlie lands but its answer is lost, and Charlie joins
    /// and sends. Alice leaving must remove only Alice. `prepare` runs on
    /// Alice before she leaves.
    private func assertLeavingKeepsAJoinerWhoSpoke(
        floodAfterCharlieSpeaks: Bool = false,
        prepare: (MLSSession, FakeMLSRelay) async throws -> MLSSession = { session, _ in session },
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let relay = FakeMLSRelay()
        let (alice, bob, group) = try await pair(relay)
        let charlie = try session("charlie", transport: relay)
        let (keyPackage, published) = try await publishedPackage(of: charlie, for: alice)
        await relay.dropNextAddResponse()
        do {
            _ = try await alice.add(keyPackage: keyPackage, verifiedFingerprint: published.fingerprint, reference: published.reference)
            XCTFail("The response should be lost", file: file, line: line)
        } catch is URLError {}
        let joined = try await charlie.join(
            group: group, keyPackageReference: published.reference, verifiedInviterFingerprint: alice.fingerprint(), profile: nil
        )
        XCTAssertTrue(joined, file: file, line: line)
        guard case .accepted = try await charlie.send(Data("I joined and spoke".utf8)) else {
            return XCTFail("Charlie could not speak", file: file, line: line)
        }
        if floodAfterCharlieSpeaks {
            for index in 0...1_000 { _ = try await bob.send(Data("flood \(index)".utf8)) }
        }
        let leaving = try await prepare(alice, relay)
        try await leaving.leave(withdrawing: [published.fingerprint])
        let charlieFingerprint = try await charlie.fingerprint()
        let evidence = try await leaving.spokenMembers()
        XCTAssertTrue(evidence.contains(charlieFingerprint), file: file, line: line)
        if floodAfterCharlieSpeaks {
            let kept = try await leaving.inbox()
            XCTAssertFalse(kept.contains { $0.sender == charlieFingerprint }, "the inbox still held the proof", file: file, line: line)
        }
        try await drain(bob)
        guard case .accepted = try await bob.send(Data("remaining members".utf8)) else {
            return XCTFail("Bob could not commit Alice's departure", file: file, line: line)
        }
        try await drain(charlie)
        let removed = try await charlie.isRemoved()
        XCTAssertFalse(removed, "leaving removed a joiner that already spoke", file: file, line: line)
        for session in [bob, charlie] {
            try await session.acknowledgeInbox(through: try await session.cursor())
        }
        try await assertConverged([bob, charlie], relay: relay, group: group, file: file, line: line)
    }

    func testLeavingAfterLostAddKeepsTheJoinerWhoAlreadySpoke() async throws {
        try await assertLeavingKeepsAJoinerWhoSpoke()
    }

    func testLeavingKeepsAJoinerWhoseMessageWasAcknowledgedBeforeRestart() async throws {
        try await assertLeavingKeepsAJoinerWhoSpoke { alice, relay in
            guard case .accepted = try await alice.flush() else { throw SessionTestError.unexpected }
            let inbox = try await alice.inbox()
            try await alice.acknowledgeInbox(through: try XCTUnwrap(inbox.last).cursor)
            let emptied = try await alice.inbox()
            XCTAssertTrue(emptied.isEmpty)
            return try self.session("alice", transport: relay)
        }
    }

    func testLeavingKeepsAJoinerWhoseMessageAFullInboxDropped() async throws {
        try await assertLeavingKeepsAJoinerWhoSpoke(floodAfterCharlieSpeaks: true)
    }

    /// The joiner's first message reaches the relay after the departing
    /// inviter last read the log and before its cleanup Remove does.
    func testDepartureKeepsAJoinerWhoseMessageLandsJustBeforeTheCleanup() async throws {
        let relay = FakeMLSRelay()
        let (alice, bob, group) = try await pair(relay)
        let charlie = try session("charlie", transport: relay)
        let (keyPackage, published) = try await publishedPackage(of: charlie, for: alice)
        guard case .accepted = try await alice.add(
            keyPackage: keyPackage, verifiedFingerprint: published.fingerprint, reference: published.reference
        ) else { return XCTFail("Add not accepted") }
        let joined = try await charlie.join(
            group: group, keyPackageReference: published.reference, verifiedInviterFingerprint: alice.fingerprint(), profile: nil
        )
        XCTAssertTrue(joined)
        await relay.beforeNextRemoval {
            _ = try await charlie.send(Data("I joined and spoke".utf8))
        }
        try await alice.leave(withdrawing: [published.fingerprint])
        try await drain(bob)
        guard case .accepted = try await bob.send(Data("remaining members".utf8)) else {
            return XCTFail("Bob could not commit Alice's departure")
        }
        try await drain(charlie)
        let removed = try await charlie.isRemoved()
        XCTAssertFalse(removed, "cleanup removed a joiner whose message preceded it")
        try await assertConverged([bob, charlie], relay: relay, group: group)
    }

    /// Alice, Bob, and a Charlie who joined but has not spoken.
    private func groupWithSilentCharlie(
        _ relay: FakeMLSRelay
    ) async throws -> (alice: MLSSession, bob: MLSSession, charlie: MLSSession, group: Data, charlieFingerprint: Data) {
        let (alice, bob, group) = try await pair(relay)
        let charlie = try session("charlie", transport: relay)
        let (keyPackage, published) = try await publishedPackage(of: charlie, for: alice)
        guard case .accepted = try await alice.add(
            keyPackage: keyPackage, verifiedFingerprint: published.fingerprint, reference: published.reference
        ) else { throw SessionTestError.unexpected }
        let joined = try await charlie.join(
            group: group, keyPackageReference: published.reference, verifiedInviterFingerprint: alice.fingerprint(), profile: nil
        )
        guard joined else { throw SessionTestError.unexpected }
        try await bob.synchronize()
        return (alice, bob, charlie, group, published.fingerprint)
    }

    /// Bob commits Alice's departure; Charlie stays and both converge.
    private func assertCharlieStays(
        bob: MLSSession, charlie: MLSSession, relay: FakeMLSRelay, group: Data, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        try await drain(bob)
        guard case .accepted = try await bob.send(Data("remaining members".utf8)) else {
            return XCTFail("Bob could not commit Alice's departure", file: file, line: line)
        }
        try await drain(charlie)
        let removed = try await charlie.isRemoved()
        XCTAssertFalse(removed, "cleanup removed a member whose message preceded it", file: file, line: line)
        for session in [bob, charlie] {
            try await session.acknowledgeInbox(through: try await session.cursor())
        }
        try await assertConverged([bob, charlie], relay: relay, group: group, file: file, line: line)
    }

    func testHeldConditionalRemoveIsRefusedForGoodOnceTheJoinerSpeaks() async throws {
        let relay = FakeMLSRelay()
        let (alice, bob, charlie, group, charlieFingerprint) = try await groupWithSilentCharlie(relay)
        await relay.deferNextRemovalBeforeStore()
        do {
            try await alice.leave(withdrawing: [charlieFingerprint])
            XCTFail("The held Remove should report a lost connection")
        } catch is URLError {}
        let held = try await XCTUnwrapAsync(await alice.pendingDelivery())
        let expected = try XCTUnwrap(held.expectedHead)
        _ = try await charlie.send(Data("I joined and spoke".utf8))
        let late = try await relay.releaseDeferredRemoval()
        XCTAssertEqual(late, .headAdvanced(head: expected + 1), "the held original landed after the joiner spoke")
        let restarted = try session("alice", transport: relay)
        let kept = try await restarted.pendingDelivery()
        XCTAssertEqual(kept, held, "the guard changed across restart")
        try await restarted.leave(withdrawing: [charlieFingerprint])
        let removals = await relay.log(group: group).filter { $0.delivery.removeWriter != nil }
        XCTAssertTrue(removals.isEmpty, "a copy of the refused Remove landed")
        try await assertCharlieStays(bob: bob, charlie: charlie, relay: relay, group: group)
    }

    func testConditionalRemoveWhoseAnswerWasLostIsRecoveredAfterRestart() async throws {
        let relay = FakeMLSRelay()
        let (alice, bob, charlie, group, charlieFingerprint) = try await groupWithSilentCharlie(relay)
        await relay.dropNextRemovalResponse()
        do {
            try await alice.leave(withdrawing: [charlieFingerprint])
            XCTFail("The answer should be lost")
        } catch is URLError {}
        let held = try await XCTUnwrapAsync(await alice.pendingDelivery())
        XCTAssertNotNil(held.expectedHead)
        _ = try await bob.send(Data("unrelated traffic after the Remove".utf8))
        let restarted = try session("alice", transport: relay)
        try await restarted.leave(withdrawing: [charlieFingerprint])
        let removals = await relay.log(group: group).filter { $0.delivery.removeWriter != nil }
        XCTAssertEqual(removals.count, 1)
        try await drain(bob)
        guard case .accepted = try await bob.send(Data("after cleanup".utf8)) else { return XCTFail("Bob blocked") }
        _ = try? await charlie.synchronize()
        let charlieRemoved = try await charlie.isRemoved()
        XCTAssertTrue(charlieRemoved, "the silent joiner was kept")
        let members = try await bob.members()
        XCTAssertEqual(members.count, 1)
        let writers = await relay.activeWriterCount(group: group)
        XCTAssertEqual(writers, 1)
    }

    func testUnrelatedActivityRefusesTheCleanupThenItRetriesWithTheNewHead() async throws {
        let relay = FakeMLSRelay()
        let (alice, bob, charlie, group, charlieFingerprint) = try await groupWithSilentCharlie(relay)
        await relay.beforeNextRemoval {
            _ = try await bob.send(Data("Bob, not Charlie".utf8))
        }
        try await alice.leave(withdrawing: [charlieFingerprint])
        let requests = await relay.conditionalRequests
        XCTAssertEqual(requests, 2, "the refused Remove was not reevaluated and sent again")
        let removals = await relay.log(group: group).filter { $0.delivery.removeWriter != nil }
        XCTAssertEqual(removals.count, 1)
        try await drain(bob)
        _ = try await bob.send(Data("after cleanup".utf8))
        _ = try? await charlie.synchronize()
        let removed = try await charlie.isRemoved()
        XCTAssertTrue(removed)
    }

    func testFullInboxKeepsTheGuardAndTheActivityThatRefusesIt() async throws {
        let relay = FakeMLSRelay()
        let (alice, bob, charlie, group, charlieFingerprint) = try await groupWithSilentCharlie(relay)
        await relay.deferNextRemovalBeforeStore()
        do {
            try await alice.leave(withdrawing: [charlieFingerprint])
            XCTFail("The held Remove should report a lost connection")
        } catch is URLError {}
        let held = try await XCTUnwrapAsync(await alice.pendingDelivery())
        _ = try await charlie.send(Data("I joined and spoke".utf8))
        for index in 0...1_000 { _ = try await bob.send(Data("flood \(index)".utf8)) }
        try await relay.releaseDeferredRemoval()
        let restarted = try session("alice", transport: relay)
        let kept = try await restarted.pendingDelivery()
        XCTAssertEqual(kept?.expectedHead, held.expectedHead)
        try await restarted.leave(withdrawing: [charlieFingerprint])
        let evidence = try await restarted.spokenMembers()
        XCTAssertTrue(evidence.contains(charlieFingerprint))
        let removals = await relay.log(group: group).filter { $0.delivery.removeWriter != nil }
        XCTAssertTrue(removals.isEmpty)
        try await assertCharlieStays(bob: bob, charlie: charlie, relay: relay, group: group)
    }

    func testOlderRelayGetsNoCleanupAndNoUnconditionalFallback() async throws {
        let relay = FakeMLSRelay()
        let (alice, bob, charlie, group, charlieFingerprint) = try await groupWithSilentCharlie(relay)
        await relay.setConditionalAppendSupported(false)
        let refused = try await bob.remove(fingerprint: charlieFingerprint, onlyIfSilent: true)
        XCTAssertEqual(refused, .superseded)
        let bobPending = try await bob.pendingDelivery()
        XCTAssertNil(bobPending)
        try await alice.leave(withdrawing: [charlieFingerprint])
        let requests = await relay.conditionalRequests
        XCTAssertEqual(requests, 0)
        let removals = await relay.log(group: group).filter { $0.delivery.removeWriter != nil }
        XCTAssertTrue(removals.isEmpty, "cleanup fell back to an unconditional Remove")
        try await assertCharlieStays(bob: bob, charlie: charlie, relay: relay, group: group)
    }

    func testExplicitRemovalOfAMemberThatSpokeStillWorks() async throws {
        let relay = FakeMLSRelay()
        let (_, bob, charlie, group, charlieFingerprint) = try await groupWithSilentCharlie(relay)
        _ = try await charlie.send(Data("I spoke".utf8))
        try await bob.synchronize()
        let evidence = try await bob.spokenMembers()
        XCTAssertTrue(evidence.contains(charlieFingerprint))
        guard case .accepted = try await bob.remove(fingerprint: charlieFingerprint) else { return XCTFail("removal refused") }
        _ = try? await charlie.synchronize()
        let removed = try await charlie.isRemoved()
        XCTAssertTrue(removed)
        let requests = await relay.conditionalRequests
        XCTAssertEqual(requests, 0)
        let writers = await relay.activeWriterCount(group: group)
        XCTAssertEqual(writers, 2)
    }

    func testRateLimitedAddIsKeptAndDeliveredOnRetry() async throws {
        let relay = FakeMLSRelay()
        let (alice, bob, group) = try await pair(relay)
        let charlie = try session("charlie", transport: relay)
        let (keyPackage, published) = try await publishedPackage(of: charlie, for: alice)
        await relay.rateLimitNext(adds: 1)
        do {
            _ = try await alice.add(keyPackage: keyPackage, verifiedFingerprint: published.fingerprint, reference: published.reference)
            XCTFail("The Add should be rate limited")
        } catch MLSRelayError.rateLimited {}
        let kept = try await alice.pendingDelivery()
        XCTAssertEqual(kept?.keyPackageReference, published.reference)
        guard case .accepted = try await alice.flush() else { return XCTFail("The retry was not accepted") }
        let joined = try await charlie.join(
            group: group, keyPackageReference: published.reference, verifiedInviterFingerprint: alice.fingerprint(), profile: nil
        )
        XCTAssertTrue(joined)
        try await assertConverged([alice, bob, charlie], relay: relay, group: group)
    }

    /// Only the store's journaled refusal ends an Add whose first request is
    /// still held: once the KeyPackage expires, the retry is refused, and so
    /// is the held request when it finally arrives.
    func testUnknownAddEndsOnlyWithTheStoresJournaledRefusal() async throws {
        let relay = FakeMLSRelay()
        let (alice, bob, group) = try await pair(relay)
        let charlie = try session("charlie", transport: relay)
        let (keyPackage, published) = try await publishedPackage(of: charlie, for: alice)
        let epoch = try await alice.epoch()
        await relay.deferNextAddBeforeStore()
        do {
            _ = try await alice.add(keyPackage: keyPackage, verifiedFingerprint: published.fingerprint, reference: published.reference)
            XCTFail("The ambiguous request should fail")
        } catch is URLError {}
        await relay.rateLimitNext(adds: 3)
        for _ in 0..<3 {
            do {
                _ = try await alice.flush()
                XCTFail("The retry should be rate limited")
            } catch MLSRelayError.rateLimited {}
        }
        let kept = try await alice.pendingDelivery()
        XCTAssertEqual(kept?.keyPackageReference, published.reference, "rate limits and timeouts are not terminal")
        await relay.expireKeyPackages()
        let flushed = try await alice.flush()
        XCTAssertEqual(flushed, .superseded)
        let discarded = try await alice.pendingDelivery()
        XCTAssertNil(discarded)
        try await relay.releaseDeferredAdd()
        let copies = await addEntries(of: published.reference, relay: relay, group: group)
        XCTAssertEqual(copies, 0, "a held copy landed after the refusal")
        let after = try await alice.epoch()
        XCTAssertEqual(after, epoch)
        let joined = try await charlie.join(
            group: group, keyPackageReference: published.reference, verifiedInviterFingerprint: alice.fingerprint(), profile: nil
        )
        XCTAssertFalse(joined)
        try await assertConverged([alice, bob], relay: relay, group: group)
    }

    func testLostAddBehindAFullInboxStaysPendingUntilTheInboxDrains() async throws {
        let relay = FakeMLSRelay()
        let (alice, bob, group) = try await pair(relay)
        for index in 0...1_000 {
            _ = try await bob.send(Data("edit \(index)".utf8))
        }
        let charlie = try session("charlie", transport: relay)
        let (keyPackage, published) = try await publishedPackage(of: charlie, for: alice)
        await relay.dropNextAppendResponse()
        do {
            _ = try await alice.add(keyPackage: keyPackage, verifiedFingerprint: published.fingerprint, reference: published.reference)
            XCTFail("The response should be lost")
        } catch is URLError {}
        do {
            _ = try await alice.flush()
            XCTFail("A full inbox accepted more messages")
        } catch MLSClientError.capacityReached {}
        let kept = try await alice.pendingDelivery()
        XCTAssertEqual(kept?.keyPackageReference, published.reference)
        let held = try await alice.inbox()
        try await alice.acknowledgeInbox(through: try XCTUnwrap(held.last).cursor)
        guard case .accepted = try await alice.flush() else { return XCTFail("The accepted Add was not applied") }
        let joined = try await charlie.join(
            group: group, keyPackageReference: published.reference, verifiedInviterFingerprint: alice.fingerprint(), profile: nil
        )
        XCTAssertTrue(joined)
        try await alice.acknowledgeInbox(through: try await alice.cursor())
        try await bob.acknowledgeInbox(through: try await bob.cursor())
        try await assertConverged([alice, bob, charlie], relay: relay, group: group)
    }

    func testStaleSenderResolvesEpochConflicts() async throws {
        let relay = FakeMLSRelay()
        let (alice, bob, group) = try await pair(relay)
        let charlie = try session("charlie", transport: relay)
        try await admit(charlie, by: alice, group: group)

        let dave = try session("dave", transport: relay)
        let token = Data(repeating: 6, count: 32)
        let published = try await dave.publishKeyPackage(pairingToken: token, profile: nil)
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
        try await alice.createGroup(Data(repeating: 8, count: 32), profile: nil)
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

    func testLeaveRevokesRelayAccessAndNextSendCommitsRemoval() async throws {
        let relay = FakeMLSRelay()
        let (alice, bob, group) = try await pair(relay)
        let charlie = try session("charlie", transport: relay)
        try await admit(charlie, by: alice, group: group)
        try await bob.synchronize()
        let bobFingerprint = try await bob.fingerprint()
        let bobAuthorization = try await bob.client.transportAuthorization()
        try await bob.leave()
        do {
            _ = try await relay.fetch(group: group, after: 0, limit: 8, authorization: bobAuthorization)
            XCTFail("Leaver can still read")
        } catch MLSRelayError.unauthorized {}
        try await alice.synchronize()
        let departures = try await alice.departures()
        XCTAssertEqual(departures, [bobFingerprint])
        let sent = try await alice.send(Data("after leave".utf8))
        guard case .accepted = sent else { return XCTFail("Send after leave not accepted") }
        let members = try await alice.members()
        XCTAssertEqual(members.count, 2)
        XCTAssertFalse(members.contains { $0.fingerprint == bobFingerprint })
        let remaining = try await alice.departures()
        XCTAssertTrue(remaining.isEmpty)
        try await charlie.synchronize()
        let inbox = try await charlie.inbox()
        XCTAssertEqual(inbox.last?.plaintext, Data("after leave".utf8))
        let charlieMembers = try await charlie.members()
        XCTAssertEqual(charlieMembers.count, 2)
        let repeated = try await alice.remove(fingerprint: bobFingerprint)
        XCTAssertEqual(repeated, .superseded)
    }

    func testOnlyLeaveDropsPlaintextFromFullInbox() async throws {
        let relay = FakeMLSRelay()
        let (alice, bob, group) = try await pair(relay)
        try await bob.synchronize()
        for index in 0...1000 { _ = try await alice.send(Data("\(index)".utf8)) }
        _ = try await bob.client.prepareMessage(Data("pending".utf8))
        do {
            _ = try await bob.synchronize()
            XCTFail("full inbox accepted another message")
        } catch MLSClientError.capacityReached {}
        let full = try await bob.inbox()
        XCTAssertEqual(full.count, 1000)

        let bobAuthorization = try await bob.client.transportAuthorization()
        try await bob.leave()
        let log = await relay.log(group: group)
        let proposal = try XCTUnwrap(log.last)
        XCTAssertEqual(proposal.delivery.kind, .proposal)
        let removal = await relay.removalCursor(of: bobAuthorization, group: group)
        XCTAssertEqual(removal, proposal.cursor)
        let cursor = try await bob.cursor()
        XCTAssertEqual(cursor, proposal.cursor - 1)
        let remaining = try await bob.inbox()
        XCTAssertEqual(remaining.map(\.plaintext), [Data("1000".utf8)])
    }

    func testLeaveCatchesUpWhenRelayLogIsFull() async throws {
        let relay = FakeMLSRelay()
        let (alice, bob, group) = try await pair(relay)
        try await bob.synchronize()
        for index in 0..<6 { _ = try await alice.send(Data("\(index)".utf8)) }
        await relay.limitUnacknowledgedEntries(to: 6)
        _ = try await bob.client.prepareMessage(Data("pending".utf8))
        do {
            _ = try await bob.flush()
            XCTFail("full relay log accepted another message")
        } catch MLSRelayError.capacityReached {}

        let bobAuthorization = try await bob.client.transportAuthorization()
        try await bob.leave()
        let log = await relay.log(group: group)
        XCTAssertEqual(log.suffix(2).map(\.delivery.kind), [.application, .proposal])
        let removal = await relay.removalCursor(of: bobAuthorization, group: group)
        XCTAssertEqual(removal, log.last?.cursor)
    }

    func testLeaveFinishesRemovalAcknowledgement() async throws {
        let relay = FakeMLSRelay()
        let (alice, bob, _) = try await pair(relay)
        let bobAuthorization = try await bob.transportAuthorizationForTesting()
        guard case .accepted(let removal) = try await alice.remove(fingerprint: bob.fingerprint()) else {
            return XCTFail("Removal not accepted")
        }
        await relay.failAcknowledgements(by: bobAuthorization, true)
        do {
            try await bob.synchronize()
            XCTFail("Failed acknowledgement succeeded")
        } catch {}
        await relay.failAcknowledgements(by: bobAuthorization, false)
        do {
            try await bob.leave()
            XCTFail("Removed member left")
        } catch MLSSessionError.removed {}
        let acknowledged = await relay.acknowledged(by: bobAuthorization)
        XCTAssertEqual(acknowledged, removal)
    }

    func testFailedAcknowledgementIsRetriedAfterRestart() async throws {
        let relay = FakeMLSRelay()
        let (alice, bob, _) = try await pair(relay)
        let bobAuthorization = try await bob.transportAuthorizationForTesting()
        guard case .accepted(let cursor) = try await alice.send(Data("hello".utf8)) else { return XCTFail("Message not accepted") }
        await relay.failAcknowledgements(by: bobAuthorization, true)
        do {
            try await bob.synchronize()
            XCTFail("Failed acknowledgement succeeded")
        } catch {}
        let processedCursor = try await bob.cursor()
        XCTAssertEqual(processedCursor, cursor)
        await relay.failAcknowledgements(by: bobAuthorization, false)
        let reopened = try session("bob", transport: relay)
        let processed = try await reopened.synchronize()
        XCTAssertEqual(processed, 0)
        let acknowledged = await relay.acknowledged(by: bobAuthorization)
        XCTAssertEqual(acknowledged, cursor)
    }

    func testFailedAcknowledgementIsRetriedWithoutNewEntries() async throws {
        let relay = FakeMLSRelay()
        let (alice, bob, _) = try await pair(relay)
        let bobAuthorization = try await bob.transportAuthorizationForTesting()
        guard case .accepted(let cursor) = try await alice.send(Data("hello".utf8)) else { return XCTFail("Message not accepted") }
        await relay.failAcknowledgements(by: bobAuthorization, true)
        do {
            try await bob.synchronize()
            XCTFail("Failed acknowledgement succeeded")
        } catch {}
        await relay.failAcknowledgements(by: bobAuthorization, false)
        try await bob.synchronize()
        let acknowledged = await relay.acknowledged(by: bobAuthorization)
        XCTAssertEqual(acknowledged, cursor)
    }

    func testJoinAcknowledgementIsRetriedAfterRestart() async throws {
        let relay = FakeMLSRelay()
        let alice = try session("alice", transport: relay)
        let bob = try session("bob", transport: relay)
        let bobAuthorization = try await bob.transportAuthorizationForTesting()
        let group = try Data.secureRandom(count: 32)
        try await alice.createGroup(group, profile: nil)
        await relay.failAcknowledgements(by: bobAuthorization, true)
        do {
            try await admit(bob, by: alice, group: group)
            XCTFail("Failed acknowledgement succeeded")
        } catch {}
        await relay.failAcknowledgements(by: bobAuthorization, false)
        let reopened = try session("bob", transport: relay)
        try await reopened.synchronize()
        let cursor = try await reopened.cursor()
        XCTAssertGreaterThan(cursor, 0)
        let acknowledged = await relay.acknowledged(by: bobAuthorization)
        XCTAssertEqual(acknowledged, cursor)
    }

    func testRemovalAcknowledgementIsRetriedAfterRestart() async throws {
        let relay = FakeMLSRelay()
        let (alice, bob, _) = try await pair(relay)
        let bobAuthorization = try await bob.transportAuthorizationForTesting()
        guard case .accepted(let removal) = try await alice.remove(fingerprint: bob.fingerprint()) else {
            return XCTFail("Removal not accepted")
        }
        await relay.failAcknowledgements(by: bobAuthorization, true)
        do {
            try await bob.synchronize()
            XCTFail("Failed acknowledgement succeeded")
        } catch {}
        let removed = try await bob.isRemoved()
        XCTAssertTrue(removed)
        await relay.failAcknowledgements(by: bobAuthorization, false)
        let reopened = try session("bob", transport: relay)
        try await reopened.synchronize()
        let acknowledged = await relay.acknowledged(by: bobAuthorization)
        XCTAssertEqual(acknowledged, removal)
        let attempts = await relay.acknowledgementCount
        try await reopened.synchronize()
        let repeated = await relay.acknowledgementCount
        XCTAssertEqual(repeated, attempts)
        do {
            _ = try await reopened.send(Data("after removal".utf8))
            XCTFail("Removed member sent")
        } catch {}
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

    func testEndpointsRequireVersionTwoPaths() throws {
        let configuration = try SyncEndpointConfiguration(
            relayURL: XCTUnwrap(URL(string: "wss://sync.example.com/v2/pairing")),
            mailboxURL: XCTUnwrap(URL(string: "https://sync.example.com:8443/v2/mls")),
            policy: .production
        )
        XCTAssertEqual(configuration.mailboxURL.absoluteString, "https://sync.example.com:8443/v2/mls")
        let local = try XCTUnwrap(URL(string: "http://127.0.0.1:9000/v2/mls"))
        XCTAssertThrowsError(try SyncEndpointConfiguration.validateMailboxURL(local, policy: .production))
        XCTAssertNoThrow(try SyncEndpointConfiguration.validateMailboxURL(local, policy: .localDevelopment))
        XCTAssertThrowsError(try SyncEndpointConfiguration.validateMailboxURL(
            XCTUnwrap(URL(string: "https://sync.example.com/v1/mailbox")), policy: .production
        ))
        XCTAssertThrowsError(try SyncEndpointConfiguration.validateRelayURL(
            XCTUnwrap(URL(string: "wss://sync.example.com/v1")), policy: .production
        ))
    }

    func testHTTPTransportRefusesPlaintextProductionEndpoint() async throws {
        let transport = HTTPMLSRelayTransport(baseURL: try XCTUnwrap(URL(string: "http://sync.example.com/v2/mls")))
        do {
            try await transport.createGroup(Data(repeating: 1, count: 32), authorization: Data(repeating: 2, count: 32))
            XCTFail("Plaintext endpoint used")
        } catch { XCTAssertEqual(error as? MLSRelayError, .insecureTransport) }
    }

    func testHTTPTransportSeparatesGatewayRateLimitsFromStoreCapacity() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TooManyRequestsProtocol.self]
        let session = URLSession(configuration: configuration)
        let cases: [(String, MLSRelayError)] = [
            ("rate-limited.example", .rateLimited),
            ("proxy.example", .rateLimited),
            ("store-full.example", .capacityReached),
        ]
        for (host, expected) in cases {
            let transport = HTTPMLSRelayTransport(baseURL: try XCTUnwrap(URL(string: "https://\(host)/v2/mls")), session: session)
            do {
                _ = try await transport.fetch(group: Data(repeating: 1, count: 32), after: 0, limit: 1, authorization: Data(repeating: 2, count: 32))
                XCTFail("\(host) answered")
            } catch {
                XCTAssertEqual(error as? MLSRelayError, expected, host)
            }
        }
    }

    func testRealRelayReportsMissingGroupAsExpiredHistory() async throws {
        guard let relay = try realRelay() else { return }
        let group = try Data.secureRandom(count: 32)
        let authorization = try Data.secureRandom(count: 32)
        do {
            _ = try await relay.fetch(group: group, after: 0, limit: 1, authorization: authorization)
            XCTFail("Fetched from a group the relay does not hold")
        } catch {
            XCTAssertEqual(error as? MLSRelayError, .historyExpired)
            XCTAssertEqual(SyncError.fromTransport(error) as? SyncError, .syncHistoryExpired)
        }
        do {
            try await relay.acknowledge(group: group, through: 0, authorization: authorization)
            XCTFail("Acknowledged a group the relay does not hold")
        } catch { XCTAssertEqual(error as? MLSRelayError, .historyExpired) }
    }

    /// The real relay refuses a conditional Remove prepared before the
    /// member spoke, and accepts one prepared after it caught up only while
    /// nothing else lands.
    func testConditionalRemoveThroughRealRelay() async throws {
        guard let relay = try realRelay() else { return }
        let (alice, bob, group) = try await pair(relay)
        let charlie = try session("charlie", transport: relay)
        let token = try Data.secureRandom(count: 32)
        let published = try await charlie.publishKeyPackage(pairingToken: token, profile: nil)
        let keyPackage = try await XCTUnwrapAsync(await alice.fetchKeyPackage(reference: published.reference, pairingToken: token))
        guard case .accepted = try await alice.add(
            keyPackage: keyPackage, verifiedFingerprint: published.fingerprint, reference: published.reference
        ) else { return XCTFail("Add not accepted") }
        let joined = try await charlie.join(
            group: group, keyPackageReference: published.reference, verifiedInviterFingerprint: alice.fingerprint(), profile: nil
        )
        XCTAssertTrue(joined)
        let supported = try await relay.supportsConditionalAppend(group: group, authorization: try await alice.client.transportAuthorization())
        XCTAssertTrue(supported)
        try await alice.synchronize()
        let observed = try await alice.cursor()
        let stale = try await alice.client.prepareRemove(fingerprint: published.fingerprint, expectedHead: observed)
        _ = try await charlie.send(Data("I spoke".utf8))
        let refused = try await alice.flush()
        XCTAssertEqual(refused, .superseded)
        let pending = try await alice.pendingDelivery()
        XCTAssertNil(pending)
        let again = try await relay.appendIfHead(stale, authorization: try await alice.client.transportAuthorization())
        guard case .headAdvanced(let head) = again, head > observed else { return XCTFail("a copy was not refused: \(again)") }
        let kept = try await alice.remove(fingerprint: published.fingerprint, onlyIfSilent: true)
        XCTAssertEqual(kept, .superseded)
        let members = try await alice.members()
        XCTAssertEqual(members.count, 3)

        try await bob.synchronize()
        let dave = try session("dave", transport: relay)
        let daveToken = try Data.secureRandom(count: 32)
        let davePackage = try await dave.publishKeyPackage(pairingToken: daveToken, profile: nil)
        let daveBytes = try await XCTUnwrapAsync(await bob.fetchKeyPackage(reference: davePackage.reference, pairingToken: daveToken))
        guard case .accepted = try await bob.add(
            keyPackage: daveBytes, verifiedFingerprint: davePackage.fingerprint, reference: davePackage.reference
        ) else { return XCTFail("Add not accepted") }
        guard case .accepted = try await bob.remove(fingerprint: davePackage.fingerprint, onlyIfSilent: true) else {
            return XCTFail("a silent member was not removed")
        }
        let remaining = try await bob.members()
        XCTAssertFalse(remaining.contains { $0.fingerprint == davePackage.fingerprint })
    }

    func testHTTPTransportMapsConditionalAppendAndCapabilities() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConditionalRelayProtocol.self]
        let session = URLSession(configuration: configuration)
        let group = Data(repeating: 1, count: 32)
        let authorization = Data(repeating: 2, count: 32)
        let removal = MLSDelivery(
            group: group, epoch: 3, kind: .commit, payload: Data([1]), removeWriter: Data(repeating: 4, count: 32), expectedHead: 7
        )
        let current = HTTPMLSRelayTransport(baseURL: try XCTUnwrap(URL(string: "https://current.example/v2/mls")), session: session)
        let supported = try await current.supportsConditionalAppend(group: group, authorization: authorization)
        XCTAssertTrue(supported)
        let refused = try await current.appendIfHead(removal, authorization: authorization)
        XCTAssertEqual(refused, .headAdvanced(head: 9))
        let behind = HTTPMLSRelayTransport(baseURL: try XCTUnwrap(URL(string: "https://behind.example/v2/mls")), session: session)
        do {
            _ = try await behind.appendIfHead(removal, authorization: authorization)
            XCTFail("a refusal at or below the expected head was accepted")
        } catch { XCTAssertEqual(error as? MLSRelayError, .invalidResponse) }
        let older = HTTPMLSRelayTransport(baseURL: try XCTUnwrap(URL(string: "https://older.example/v2/mls")), session: session)
        let unsupported = try await older.supportsConditionalAppend(group: group, authorization: authorization)
        XCTAssertFalse(unsupported)
        do {
            _ = try await older.appendIfHead(removal, authorization: authorization)
            XCTFail("an older relay accepted a conditional append")
        } catch { XCTAssertEqual(error as? MLSRelayError, .rejected(status: 400, code: "invalidRequest")) }
        do {
            _ = try await current.append(removal, authorization: authorization)
            XCTFail("a guarded Remove was sent unconditionally")
        } catch { XCTAssertEqual(error as? MLSRelayError, .invalidRequest) }
        do {
            _ = try await current.appendIfHead(removal.withoutExpectedHead, authorization: authorization)
            XCTFail("a Remove without a guard was sent conditionally")
        } catch { XCTAssertEqual(error as? MLSRelayError, .invalidRequest) }
    }

    func testThreeSessionsThroughRealRelay() async throws {
        guard let relay = try realRelay() else { return }

        let (alice, bob, group) = try await pair(relay)
        let token = try Data.secureRandom(count: 32)
        let charlie = try session("charlie", transport: relay)
        let published = try await charlie.publishKeyPackage(pairingToken: token, profile: nil)
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
        let joined = try await charlie.join(group: group, keyPackageReference: published.reference, verifiedInviterFingerprint: alice.fingerprint(), profile: nil)
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

/// Answers every request with HTTP 429 and the body the host names: the
/// relay's admission limiter, a proxy without a JSON body, or the delivery
/// store.
private final class TooManyRequestsProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body: Data = switch url.host {
        case "rate-limited.example": Data(#"{"error":"rateLimited","version":2}"#.utf8)
        case "store-full.example": Data(#"{"error":"deliveryCapacity","version":2}"#.utf8)
        default: Data("Too Many Requests".utf8)
        }
        let response = HTTPURLResponse(url: url, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private enum SessionTestError: Error {
    case unexpected
}

/// A relay that supports conditional appends (`current`), refuses with an
/// inconsistent head (`behind`), or predates them (`older`).
private final class ConditionalRelayProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let operation = url.lastPathComponent
        let (status, body): (Int, String) = switch (url.host, operation) {
        case ("older.example", _): (400, #"{"error":"invalidRequest","version":2}"#)
        case (_, "capabilities"): (200, #"{"conditionalAppend":true,"version":2}"#)
        case ("behind.example", _): (409, #"{"error":"headAdvanced","head":7,"version":2}"#)
        default: (409, #"{"error":"headAdvanced","head":9,"version":2}"#)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
