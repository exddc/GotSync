import CryptoKit
import Foundation
import GotSyncMLS
import XCTest
@testable import GotSync

@MainActor
final class SyncEngineMLSTests: XCTestCase {
    private var root: URL!
    private var relay: FakeMLSRelay!
    private var rendezvous: FakePairingRendezvous!
    private var stores: [String: MemorySecretStore] = [:]
    private var engines: [SyncEngine] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        relay = FakeMLSRelay()
        rendezvous = FakePairingRendezvous()
        stores = [:]
        engines = []
    }

    override func tearDown() async throws {
        for engine in engines { await engine.stop() }
        try? FileManager.default.removeItem(at: root)
    }

    private func engine(_ name: String) -> SyncEngine {
        let store = stores[name] ?? MemorySecretStore()
        stores[name] = store
        let engine = SyncEngine(
            keychain: store,
            baseDirectory: root.appendingPathComponent(name),
            pairingRetryDelayNanoseconds: 20_000_000,
            mlsTransport: relay,
            rendezvous: rendezvous,
            syncIntervalNanoseconds: 50_000_000
        )
        engines.append(engine)
        return engine
    }

    private func wait(
        _ stage: String,
        timeout: Duration = .seconds(10),
        file: StaticString = #filePath,
        line: UInt = #line,
        until predicate: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while try await !predicate() {
            guard ContinuousClock.now < deadline else {
                let details = engines.map { "\($0.phase): \($0.errorMessage ?? "no error")" }.joined(separator: "; ")
                XCTFail("Timed out at \(stage): \(details)", file: file, line: line)
                throw SyncTestError.timeout
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func invite(_ host: SyncEngine) async throws -> URL {
        host.createPrivateSync()
        try await wait("invitation") { host.invitationURL != nil }
        return try XCTUnwrap(host.invitationURL)
    }

    private func pair(_ host: SyncEngine, _ joiner: SyncEngine, usePhrase: Bool = false) async throws {
        let url = try await invite(host)
        if usePhrase {
            joiner.joinPrivateSync(phrase: try XCTUnwrap(host.invitationPhrase))
        } else {
            joiner.joinPrivateSync(url: url)
        }
        try await wait("safety code") { host.isHostApprovalPending && joiner.safetyCode != nil }
        XCTAssertEqual(host.safetyCode, joiner.safetyCode)
        host.approveSafetyCode()
        try await wait("paired") { host.isPaired && joiner.isPaired }
    }

    private func groupID(_ engine: SyncEngine) async throws -> Data {
        try await XCTUnwrapAsync(await engine.mlsSessionForTesting?.group())
    }

    private func fingerprint(_ engine: SyncEngine) async throws -> Data {
        try await XCTUnwrapAsync(await engine.mlsSessionForTesting?.fingerprint())
    }

    func testPairingMergesBothReplicasAndReplicatesEdits() async throws {
        let host = engine("host")
        let joiner = engine("joiner")
        XCTAssertTrue(host.addTask(title: "Host task"))
        XCTAssertTrue(joiner.addTask(title: "Joiner task"))
        try await pair(host, joiner)
        XCTAssertEqual(host.linkedMemberCount, 2)
        XCTAssertEqual(joiner.linkedMemberCount, 2)
        try await wait("merge") { host.tasks.count == 2 && joiner.tasks.count == 2 }

        XCTAssertTrue(joiner.addTask(title: "After link"))
        try await wait("convergence") {
            host.tasks.count == 3 && host.phase == .synced && joiner.phase == .synced && joiner.pendingMailboxOperationCount == 0
        }
        host.toggleTask(try XCTUnwrap(host.tasks.first { $0.titleValue == "After link" }))
        try await wait("toggle") { joiner.tasks.first { $0.titleValue == "After link" }?.isCompleted == true }
        XCTAssertEqual(Set(host.tasks.map(\.titleValue)), Set(joiner.tasks.map(\.titleValue)))
    }

    func testPhraseJoinLearnsGroupFromSealedOffer() async throws {
        let host = engine("host")
        let joiner = engine("joiner")
        XCTAssertTrue(host.addTask(title: "Shared"))
        try await pair(host, joiner, usePhrase: true)
        try await wait("provisioned") { joiner.tasks.map(\.titleValue) == ["Shared"] }
        let hostGroup = try await groupID(host)
        let joinerGroup = try await groupID(joiner)
        XCTAssertEqual(hostGroup, joinerGroup)
    }

    func testInviterProvidesHistoryOfOfflineMemberAndRestartCatchesUp() async throws {
        let host = engine("host")
        var second = engine("second")
        try await pair(host, second)
        XCTAssertTrue(second.addTask(title: "From second"))
        try await wait("host receives") { host.tasks.count == 1 && second.pendingMailboxOperationCount == 0 }
        await second.stop()

        let third = engine("third")
        try await pair(host, third)
        try await wait("three members") { host.linkedMemberCount == 3 && third.linkedMemberCount == 3 }
        try await wait("provider history") { third.tasks.map(\.titleValue) == ["From second"] }

        XCTAssertTrue(third.addTask(title: "From third"))
        XCTAssertTrue(host.addTask(title: "From host"))
        try await wait("host converges") { host.tasks.count == 3 }
        second = engine("second")
        XCTAssertTrue(second.isPaired)
        try await wait("restart catch-up") { second.tasks.count == 3 && second.linkedMemberCount == 3 }
        XCTAssertEqual(Set(second.tasks.map(\.titleValue)), Set(third.tasks.map(\.titleValue)))
    }

    func testJoinerInterruptedAfterAdmissionStillReceivesProviderHistory() async throws {
        let host = engine("host")
        let second = engine("second")
        try await pair(host, second)
        XCTAssertTrue(second.addTask(title: "From second"))
        try await wait("host receives") { host.tasks.count == 1 && second.pendingMailboxOperationCount == 0 }
        await second.stop()

        await relay.failNextWelcomeAcknowledgement()
        var third = engine("third")
        third.joinPrivateSync(url: try await invite(host))
        try await wait("safety code") { host.isHostApprovalPending && third.safetyCode != nil }
        host.approveSafetyCode()
        try await wait("interrupted after admission") { third.phase == .failed }
        let admittedGroup = try await third.mlsSessionForTesting?.group()
        XCTAssertNotNil(admittedGroup)
        XCTAssertFalse(third.isPaired)
        await third.stop()

        third = engine("third")
        try await wait("recovered membership") { third.isPaired && third.linkedMemberCount == 3 }
        try await wait("provider history") { third.tasks.map(\.titleValue) == ["From second"] }
    }

    func testStaleSyncCycleCannotRestoreTasksAfterErase() async throws {
        try await assertStaleSyncCycleIsDiscarded(expectedTitles: []) { $0.eraseLocalData() }
    }

    func testStaleSyncCycleCannotCarryOperationsAcrossUnlink() async throws {
        try await assertStaleSyncCycleIsDiscarded(expectedTitles: ["Before"]) { $0.unlinkAndKeepTasks() }
    }

    private func assertStaleSyncCycleIsDiscarded(
        expectedTitles: [String],
        file: StaticString = #filePath,
        line: UInt = #line,
        teardown: (SyncEngine) -> Void
    ) async throws {
        let host = engine("host")
        let joiner = engine("joiner")
        XCTAssertTrue(host.addTask(title: "Before"))
        try await pair(host, joiner)
        try await wait("converged") {
            joiner.tasks.count == 1 && host.phase == .synced && joiner.phase == .synced
                && host.pendingMailboxOperationCount == 0 && joiner.pendingMailboxOperationCount == 0
        }

        let gate = SyncTestGate()
        host.inboxReadHookForTesting = { await gate.pause() }
        XCTAssertTrue(joiner.addTask(title: "Stale"))
        try await wait("cycle paused") { gate.isPaused }
        host.inboxReadHookForTesting = nil
        teardown(host)
        gate.release()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(host.tasks.map(\.titleValue), expectedTitles, file: file, line: line)
        await host.stop()
        let reopened = engine("host")
        XCTAssertEqual(reopened.tasks.map(\.titleValue), expectedTitles, file: file, line: line)
    }

    func testBackgroundFlushUploadsPendingEdits() async throws {
        let host = engine("host")
        let joiner = engine("joiner")
        try await pair(host, joiner)
        try await wait("synced") { host.phase == .synced }
        host.applicationDidEnterBackground()
        XCTAssertTrue(host.addTask(title: "Saved while inactive"))
        XCTAssertEqual(host.pendingMailboxOperationCount, 1)
        await host.performBackgroundMailboxFlushWork()
        XCTAssertEqual(host.pendingMailboxOperationCount, 0)
        try await wait("delivered") { joiner.tasks.count == 1 }
    }

    func testRejectedSafetyCodeDeclinesJoiner() async throws {
        let host = engine("host")
        let joiner = engine("joiner")
        joiner.joinPrivateSync(url: try await invite(host))
        try await wait("safety code") { host.isHostApprovalPending }
        host.rejectSafetyCode()
        try await wait("declined") { joiner.phase == .failed && host.phase == .unpaired }
        XCTAssertEqual(joiner.errorMessage, SyncError.pairingDeclined.errorDescription)
        XCTAssertFalse(host.isPaired)
        XCTAssertFalse(joiner.isPaired)
        let joinerGroup = try await joiner.mlsSessionForTesting?.group()
        XCTAssertNil(joinerGroup)
    }

    func testSubstitutedKeyPackageIsRejected() async throws {
        let host = engine("host")
        let joiner = engine("joiner")
        let attacker = try MLSClient(
            directory: root.appendingPathComponent("attacker"),
            deviceID: Data(repeating: 0xA0, count: 16),
            stateKey: InMemoryStateKeyProvider()
        )
        await relay.substituteNextKeyPackageFetch(with: try await attacker.joiningIdentity().keyPackage)
        joiner.joinPrivateSync(url: try await invite(host))
        try await wait("inviter rejects") { host.phase == .failed }
        XCTAssertEqual(host.errorMessage, SyncError.invalidPairMessage.errorDescription)
        XCTAssertFalse(host.isHostApprovalPending)
        try await wait("joiner declined") { joiner.phase == .failed }
        XCTAssertFalse(joiner.isPaired)
    }

    func testStolenInvitationSubstitutingResponseShowsDifferentSafetyCode() async throws {
        let host = engine("host")
        let joiner = engine("joiner")
        let url = try await invite(host)
        let invitation = try Invitation.from(url: url, scheme: "gotsync-tests")
        let attacker = try MLSSession(
            directory: root.appendingPathComponent("attacker"),
            deviceID: Data(repeating: 0xA1, count: 16),
            secretStore: MemorySecretStore(),
            transport: relay
        )
        let published = try await attacker.publishKeyPackage(pairingToken: invitation.pairingToken)
        let forged = try PairingFrame.response(keyPackageReference: published.reference, joinerFingerprint: published.fingerprint)
            .seal(for: invitation, from: .fromJoiner)
        await rendezvous.setInterceptor { frame in
            guard (try? PairingFrame.open(frame, for: invitation, from: .fromJoiner)).map({
                if case .response = $0 { return true } else { return false }
            }) == true else { return [frame] }
            return [forged]
        }
        joiner.joinPrivateSync(url: url)
        try await wait("codes shown") { host.isHostApprovalPending && joiner.safetyCode != nil }
        XCTAssertNotEqual(host.safetyCode, joiner.safetyCode)
        host.rejectSafetyCode()
        try await wait("rejected") { joiner.phase == .failed }
        let members = await relay.log(group: invitation.groupID!)
        XCTAssertTrue(members.isEmpty)
    }

    func testSubstitutedInviterFingerprintIsRejected() async throws {
        let host = engine("host")
        let joiner = engine("joiner")
        let real = try Invitation.from(url: try await invite(host), scheme: "gotsync-tests")
        let substituted = try Invitation(
            secret: real.secret,
            groupID: real.groupID,
            inviterFingerprint: Data(repeating: 0xEE, count: 32)
        )
        joiner.joinPrivateSync(url: try substituted.url(scheme: "gotsync-tests"))
        try await wait("joiner rejects") { joiner.phase == .failed }
        XCTAssertEqual(joiner.errorMessage, SyncError.invalidPairMessage.errorDescription)
        let reference = await relay.lastPublishedReference
        XCTAssertNil(reference)
        XCTAssertFalse(host.isHostApprovalPending)
    }

    func testOfferForgedWithoutInvitationSecretIsRejected() async throws {
        let host = engine("host")
        let joiner = engine("joiner")
        let real = try Invitation.from(url: try await invite(host), scheme: "gotsync-tests")
        let forger = try Invitation(secret: Data(repeating: 0x55, count: 16))
        let forged = try PairingFrame.offer(groupID: try XCTUnwrap(real.groupID), inviterFingerprint: Data(repeating: 0xEE, count: 32))
            .seal(for: forger, from: .fromInviter)
        await rendezvous.setInterceptor { _ in [forged] }
        joiner.joinPrivateSync(phrase: try XCTUnwrap(host.invitationPhrase))
        try await wait("joiner rejects") { joiner.phase == .failed }
        XCTAssertEqual(joiner.errorMessage, SyncError.invalidPairMessage.errorDescription)
        XCTAssertFalse(joiner.isPaired)
    }

    func testWelcomeSignedByNonInviterIsRejected() async throws {
        let host = engine("host")
        let joiner = engine("joiner")
        let invitation = try Invitation.from(url: try await invite(host), scheme: "gotsync-tests")
        joiner.joinPrivateSync(url: try XCTUnwrap(host.invitationURL))
        try await wait("published") { await self.relay.lastPublishedReference != nil && host.isHostApprovalPending }
        let reference = try await XCTUnwrapAsync(await relay.lastPublishedReference)
        let keyPackage = try await XCTUnwrapAsync(await relay.publishedKeyPackage(reference: reference))
        let attacker = try MLSClient(
            directory: root.appendingPathComponent("attacker"),
            deviceID: Data(repeating: 0xA2, count: 16),
            stateKey: InMemoryStateKeyProvider()
        )
        try await attacker.createGroup(id: try XCTUnwrap(invitation.groupID))
        let delivery = try await attacker.prepareAdd(
            keyPackage: keyPackage, verifiedFingerprint: try await fingerprint(joiner), reference: reference
        )
        await relay.inject(delivery)
        try await wait("joiner rejects") { joiner.phase == .failed }
        XCTAssertFalse(joiner.isPaired)
        let joinerGroup = try await joiner.mlsSessionForTesting?.group()
        XCTAssertNil(joinerGroup)
    }

    func testApplicationMessageFromNonMemberIsRejected() async throws {
        let host = engine("host")
        let joiner = engine("joiner")
        try await pair(host, joiner)
        let group = try await groupID(host)
        try await wait("synced") { joiner.phase == .synced }

        let outsider = try MLSClient(
            directory: root.appendingPathComponent("outsider"),
            deviceID: Data(repeating: 0xA3, count: 16),
            stateKey: InMemoryStateKeyProvider()
        )
        try await outsider.createGroup(id: group)
        var forgedReplica = try TaskReplica(deviceID: ReplicaDeviceID(uuid: UUID()))
        let operation = try forgedReplica.createTask(title: "Injected")
        let message = try await outsider.prepareMessage(ReplicationMessage.operations([operation]).encoded())
        await relay.inject(message)
        let cursor = await relay.log(group: group).count
        try await wait("rejected") {
            try await joiner.mlsSessionForTesting?.rejectedApplicationCursors().contains(UInt64(cursor)) == true
        }
        XCTAssertTrue(joiner.tasks.isEmpty)
        XCTAssertTrue(host.addTask(title: "Still syncing"))
        try await wait("not blocked") { joiner.tasks.map(\.titleValue) == ["Still syncing"] }
    }

    func testReplayedAndTamperedMessagesAreRejected() async throws {
        let host = engine("host")
        let joiner = engine("joiner")
        try await pair(host, joiner)
        let group = try await groupID(host)
        XCTAssertTrue(host.addTask(title: "Original"))
        try await wait("delivered") { joiner.tasks.count == 1 && host.pendingMailboxOperationCount == 0 }
        let log = await relay.log(group: group)
        let original = try XCTUnwrap(log.last { $0.delivery.kind == .application })

        await relay.inject(original.delivery)
        let replayCursor = UInt64(await relay.log(group: group).count)
        var payload = original.delivery.payload
        payload[payload.count - 1] ^= 0x01
        await relay.inject(MLSDelivery(group: group, epoch: original.delivery.epoch, kind: .application, payload: payload))
        let tamperCursor = UInt64(await relay.log(group: group).count)
        try await wait("both rejected") {
            let rejected = try await joiner.mlsSessionForTesting?.rejectedApplicationCursors() ?? []
            return rejected.contains(replayCursor) && rejected.contains(tamperCursor)
        }
        XCTAssertEqual(joiner.tasks.map(\.titleValue), ["Original"])
        XCTAssertTrue(host.addTask(title: "Next"))
        try await wait("still syncing") { joiner.tasks.count == 2 }
    }

    func testInvalidCommitBlocksSyncAndIsSurfaced() async throws {
        let host = engine("host")
        let joiner = engine("joiner")
        try await pair(host, joiner)
        let group = try await groupID(host)
        try await wait("synced") { joiner.phase == .synced }
        let epoch = try await XCTUnwrapAsync(await joiner.mlsSessionForTesting?.epoch())
        await relay.inject(MLSDelivery(group: group, epoch: epoch, kind: .commit, payload: Data("forged".utf8)))
        try await wait("blocked") { joiner.phase == .failed }
        XCTAssertEqual(joiner.mailboxError, .syncHistoryBlocked)
        XCTAssertTrue(joiner.mailboxRequiresRepair)
        XCTAssertEqual(joiner.errorMessage, SyncError.syncHistoryBlocked.errorDescription)
        XCTAssertTrue(joiner.isPaired)
    }

    func testUnlinkAndEraseResetTheMLSSession() async throws {
        let host = engine("host")
        let joiner = engine("joiner")
        XCTAssertTrue(joiner.addTask(title: "Kept"))
        try await pair(host, joiner)
        let before = try await fingerprint(joiner)
        let checkpointURL = root.appendingPathComponent("joiner").appendingPathComponent(ReplicationCheckpoint.filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpointURL.path))

        joiner.unlinkAndKeepTasks()
        XCTAssertFalse(joiner.isPaired)
        XCTAssertEqual(joiner.phase, .unpaired)
        XCTAssertEqual(joiner.tasks.map(\.titleValue), ["Kept"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointURL.path))
        let afterUnlink = try await fingerprint(joiner)
        XCTAssertNotEqual(afterUnlink, before)
        let unlinkedGroup = try await joiner.mlsSessionForTesting?.group()
        XCTAssertNil(unlinkedGroup)

        let hostBefore = try await fingerprint(host)
        host.eraseLocalData()
        XCTAssertFalse(host.isPaired)
        XCTAssertTrue(host.tasks.isEmpty)
        let hostAfter = try await fingerprint(host)
        XCTAssertNotEqual(hostAfter, hostBefore)
        let reopened = engine("host")
        XCTAssertFalse(reopened.isPaired)
        let reopenedFingerprint = try await fingerprint(reopened)
        XCTAssertEqual(reopenedFingerprint, hostAfter)
    }

    func testLegacyCredentialsAreResetAndTasksKept() async throws {
        let store = MemorySecretStore()
        stores["legacy"] = store
        let identity = try InstallIdentity.loadOrCreate(store: store)
        let directory = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var replica = try TaskReplica(
            deviceID: ReplicaDeviceID(bytes: identity.deviceID),
            persistenceURL: directory.appendingPathComponent("replica-v1.json")
        )
        try replica.createTask(title: "From version 1")
        let credentialStore = CredentialStore(keychain: store)
        try credentialStore.saveActive(PairCredentials(
            pairRoot: Data(repeating: 0x11, count: 32),
            pairID: Data(repeating: 0x22, count: 16),
            role: .host,
            localDeviceID: identity.deviceID,
            remoteDeviceID: Data(repeating: 0x33, count: 16)
        ))

        let upgraded = engine("legacy")
        XCTAssertFalse(upgraded.isPaired)
        XCTAssertEqual(upgraded.phase, .unpaired)
        XCTAssertEqual(upgraded.tasks.map(\.titleValue), ["From version 1"])
        XCTAssertEqual(upgraded.errorMessage, SyncError.relinkRequired.errorDescription)
        XCTAssertNil(try credentialStore.activeGroup())
        XCTAssertFalse(try credentialStore.hasPairingData())
    }

    func testMLSStateKeyAllowsBackgroundAccessOnThisDeviceOnly() async throws {
        let engine = engine("device")
        _ = try await fingerprint(engine)
        XCTAssertEqual(
            stores["device"]?.accessibility(account: SecretStoreMLSStateKey.account),
            .afterFirstUnlockThisDeviceOnly
        )
    }
}

private enum SyncTestError: Error {
    case timeout
}

@MainActor
private final class SyncTestGate {
    private(set) var isPaused = false
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        isPaused = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
