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

    private func engine(
        _ name: String,
        approvalTimeoutNanoseconds: UInt64 = SyncTiming.approvalTimeoutNanoseconds,
        provisionalMemberWindow: TimeInterval = SyncTiming.provisionalMemberWindow,
        departureRetryDelayNanoseconds: ClosedRange<UInt64> = 1_000_000_000...30_000_000_000
    ) -> SyncEngine {
        let store = stores[name] ?? MemorySecretStore()
        stores[name] = store
        let engine = SyncEngine(
            configuration: try! SyncConfiguration(
                relayURL: TestEndpoints.relayURL,
                mailboxURL: TestEndpoints.mailboxURL,
                storageDirectory: root.appendingPathComponent(name),
                invitationURLScheme: "gotsync-tests",
                endpointPolicy: .localDevelopment
            ),
            secretStore: store,
            backgroundMailboxScheduler: nil,
            pairingRetryDelayNanoseconds: 20_000_000,
            mlsTransport: relay,
            rendezvous: rendezvous,
            syncIntervalNanoseconds: 50_000_000,
            approvalTimeoutNanoseconds: approvalTimeoutNanoseconds,
            provisionalMemberWindow: provisionalMemberWindow,
            departureRetryDelayNanoseconds: departureRetryDelayNanoseconds
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
        let nonce = Data(repeating: 0x42, count: 32)
        let commitment = try PairingFrame.commitment(PairingSafetyCode.commitment(
            groupID: try XCTUnwrap(invitation.groupID),
            inviterFingerprint: try XCTUnwrap(invitation.inviterFingerprint),
            keyPackageReference: published.reference,
            joinerFingerprint: published.fingerprint,
            joinerNonce: nonce
        )).seal(for: invitation, from: .fromJoiner)
        let reveal = try PairingFrame.response(
            keyPackageReference: published.reference, joinerFingerprint: published.fingerprint, joinerNonce: nonce
        ).seal(for: invitation, from: .fromJoiner)
        await rendezvous.setInterceptor { frame in
            switch try? PairingFrame.open(frame, for: invitation, from: .fromJoiner) {
            case .commitment?: [commitment]
            case .response?: [reveal]
            default: [frame]
            }
        }
        joiner.joinPrivateSync(url: url)
        try await wait("codes shown") { host.isHostApprovalPending && joiner.safetyCode != nil }
        XCTAssertNotEqual(host.safetyCode, joiner.safetyCode)
        host.rejectSafetyCode()
        try await wait("rejected") { joiner.phase == .failed }
        let members = await relay.log(group: invitation.groupID!)
        XCTAssertTrue(members.isEmpty)
    }

    /// An invitation holder that connects first and learns the inviter's
    /// nonce cannot then reveal a different KeyPackage, such as one ground
    /// to reproduce another device's safety code.
    func testRevealMustMatchCommitmentMadeBeforeInviterNonce() async throws {
        for substituteCommitment in [false, true] {
            let host = engine(substituteCommitment ? "host-recommit" : "host-reveal")
            let invitation = try Invitation.from(url: try await invite(host), scheme: "gotsync-tests")
            let group = try XCTUnwrap(invitation.groupID)
            let inviter = try XCTUnwrap(invitation.inviterFingerprint)
            let attacker = try MLSSession(
                directory: root.appendingPathComponent("attacker-\(substituteCommitment)"),
                deviceID: Data(repeating: 0xA4, count: 16),
                secretStore: MemorySecretStore(),
                transport: relay
            )
            let connection = try await rendezvous.connect(route: invitation.route)
            let committed = try await attacker.publishKeyPackage(pairingToken: invitation.pairingToken)
            let nonce = Data(repeating: 0x24, count: 32)
            func commitment(_ package: MLSPublishedKeyPackage) throws -> Data {
                try PairingFrame.commitment(PairingSafetyCode.commitment(
                    groupID: group, inviterFingerprint: inviter, keyPackageReference: package.reference,
                    joinerFingerprint: package.fingerprint, joinerNonce: nonce
                )).seal(for: invitation, from: .fromJoiner)
            }
            var inviterNonce: Data?
            while inviterNonce == nil {
                switch try await connection.receive() {
                case .peerReady: continue
                case .binary(let frame):
                    switch try PairingFrame.open(frame, for: invitation, from: .fromInviter) {
                    case .offer: try await connection.send(commitment(committed))
                    case .nonce(let value): inviterNonce = value
                    default: XCTFail("Unexpected frame")
                    }
                default: XCTFail("Unexpected event")
                }
            }
            let ground = try await attacker.publishKeyPackage(pairingToken: invitation.pairingToken)
            if substituteCommitment {
                try await connection.send(commitment(ground))
            } else {
                try await connection.send(PairingFrame.response(
                    keyPackageReference: ground.reference, joinerFingerprint: ground.fingerprint, joinerNonce: nonce
                ).seal(for: invitation, from: .fromJoiner))
            }
            try await wait("inviter rejects") { host.phase == .failed }
            XCTAssertEqual(host.errorMessage, SyncError.invalidPairMessage.errorDescription)
            XCTAssertNil(host.safetyCode)
            XCTAssertFalse(host.isHostApprovalPending)
            await connection.cancel()
        }
    }

    func testSafetyCodeDependsOnBothNonces() {
        let group = Data(repeating: 1, count: 32)
        let inviter = Data(repeating: 2, count: 32)
        let joiner = Data(repeating: 3, count: 32)
        let codes = Set((0..<32).map { byte in
            PairingSafetyCode.code(
                groupID: group, inviterFingerprint: inviter, joinerFingerprint: joiner,
                inviterNonce: Data(repeating: UInt8(byte), count: 32), joinerNonce: Data(repeating: 9, count: 32)
            )
        })
        XCTAssertGreaterThan(codes.count, 28)
        XCTAssertNotEqual(
            PairingSafetyCode.code(groupID: group, inviterFingerprint: inviter, joinerFingerprint: joiner, inviterNonce: group, joinerNonce: inviter),
            PairingSafetyCode.code(groupID: group, inviterFingerprint: inviter, joinerFingerprint: joiner, inviterNonce: group, joinerNonce: joiner)
        )
    }

    func testUnapprovedSafetyCodeExpiresBeforeKeyPackage() async throws {
        let host = engine("host", approvalTimeoutNanoseconds: 300_000_000)
        let joiner = engine("joiner")
        XCTAssertLessThan(SyncTiming.approvalTimeoutNanoseconds, 900_000_000_000)
        joiner.joinPrivateSync(url: try await invite(host))
        try await wait("safety code") { host.isHostApprovalPending }
        try await wait("expired") { host.phase == .failed && joiner.phase == .failed }
        XCTAssertEqual(host.errorMessage, SyncError.approvalExpired.errorDescription)
        XCTAssertFalse(host.isHostApprovalPending)
        XCTAssertNil(host.safetyCode)
        XCTAssertEqual(joiner.errorMessage, SyncError.pairingDeclined.errorDescription)
        host.approveSafetyCode()
        XCTAssertFalse(host.isPaired)
        let group = try await host.mlsSessionForTesting?.group()
        XCTAssertNil(group)
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

    // MARK: - Removal and leave

    private func linkedGroup(_ names: [String]) async throws -> [SyncEngine] {
        let host = engine(names[0])
        var linked = [host]
        for name in names.dropFirst() {
            let joiner = engine(name)
            try await pair(host, joiner)
            linked.append(joiner)
            let expected = linked.count
            let current = linked
            try await wait("membership") { current.allSatisfy { $0.linkedMemberCount == expected } }
        }
        let all = linked
        try await wait("synced") { all.allSatisfy { $0.phase == .synced && $0.pendingMailboxOperationCount == 0 } }
        return linked
    }

    /// Copies a device's MLS directory and state key, as a thief with disk
    /// access would.
    private func retainedState(of name: String, engine: SyncEngine, copy: String) async throws -> MLSClient {
        let source = engine.mlsDirectoryForTesting
        let destination = root.appendingPathComponent(copy)
        try FileManager.default.copyItem(at: source, to: destination)
        let key = try XCTUnwrap(stores[name]?.read(account: SecretStoreMLSStateKey.account))
        return try MLSClient(
            directory: destination,
            deviceID: engine.localDeviceID,
            stateKey: InMemoryStateKeyProvider(key: SymmetricKey(data: key))
        )
    }

    private func assertLockedOut(
        _ retained: MLSClient,
        replay: MLSClient,
        group: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let authorization = try await retained.transportAuthorization()
        let removal = try await XCTUnwrapAsync(await relay.removalCursor(of: authorization, group: group))
        if let readable = try? await relay.fetch(group: group, after: 0, limit: 32, authorization: authorization) {
            XCTAssertTrue(readable.allSatisfy { $0.cursor <= removal }, "relay served entries after removal", file: file, line: line)
        }
        let epoch = try await retained.epoch()
        do {
            _ = try await relay.append(
                MLSDelivery(group: group, epoch: epoch + 1, kind: .application, payload: Data("forged".utf8)),
                authorization: authorization
            )
            XCTFail("relay accepted a removed writer", file: file, line: line)
        } catch MLSRelayError.unauthorized {}

        let log = await relay.log(group: group)
        let later = log.filter { $0.delivery.kind == .application && $0.delivery.epoch > epoch }
        XCTAssertFalse(later.isEmpty, "no later-epoch application message to test", file: file, line: line)
        for entry in later {
            let relabeled = MLSDelivery(group: group, epoch: epoch, kind: .application, payload: entry.delivery.payload)
            try await retained.process(relabeled, cursor: entry.cursor)
        }
        let inbox = try await retained.inbox()
        let rejected = try await retained.rejectedApplicationCursors()
        XCTAssertTrue(inbox.allSatisfy { $0.cursor < removal }, "retained state decrypted a later epoch", file: file, line: line)
        XCTAssertTrue(Set(later.map(\.cursor)).isSubset(of: Set(rejected)), file: file, line: line)

        var removed = false
        for entry in log where entry.cursor > (try await replay.cursor()) {
            if removed {
                do {
                    try await replay.process(entry.delivery, cursor: entry.cursor)
                    XCTFail("removed state processed a later entry", file: file, line: line)
                } catch MLSClientError.invalidState {}
            } else {
                try await replay.process(entry.delivery, cursor: entry.cursor)
                removed = try await replay.isRemoved()
            }
        }
        XCTAssertTrue(removed, "replaying the log did not remove the retained state", file: file, line: line)
        let replayed = try await replay.inbox()
        XCTAssertTrue(replayed.allSatisfy { $0.cursor < removal }, file: file, line: line)
    }

    /// In the group of three the removed device is offline, as a stolen
    /// device would be, and a member other than its inviter removes it.
    func testRemovedDeviceWithRetainedStateCannotReadLaterEpochs() async throws {
        for size in [2, 3] {
            let names = (0..<size).map { "remove\(size)-\($0)" }
            let linked = try await linkedGroup(names)
            let target = linked[1]
            let remover = linked[size - 1] === target ? linked[0] : linked[size - 1]
            let group = try await groupID(remover)
            let retained = try await retainedState(of: names[1], engine: target, copy: "stolen\(size)")
            let replay = try await retainedState(of: names[1], engine: target, copy: "stolen\(size)-replay")
            if size == 3 {
                await target.stop()
            }
            let device = try XCTUnwrap(remover.linkedDevices.first { $0.deviceID == target.localDeviceID })
            XCTAssertFalse(remover.removeDevice(fingerprint: Data(repeating: 1, count: 32)))
            XCTAssertFalse(remover.removeDevice(try XCTUnwrap(remover.linkedDevices.first(where: \.isCurrentDevice))))
            XCTAssertTrue(remover.removeDevice(device))
            let remaining = linked.filter { $0 !== target }
            try await wait("removed") { remaining.allSatisfy { $0.linkedMemberCount == size - 1 } }
            XCTAssertFalse(remover.linkedDevices.contains { $0.deviceID == target.localDeviceID })
            let title = "After removal \(size)"
            XCTAssertTrue(remover.addTask(title: title))
            try await wait("others converge") {
                remaining.allSatisfy { $0.tasks.contains { $0.titleValue == title } } && remover.pendingMailboxOperationCount == 0
            }
            let removedDevice = size == 3 ? engine(names[1]) : target
            try await wait("removal detected") { !removedDevice.isPaired }
            XCTAssertEqual(removedDevice.errorMessage, SyncError.removedFromGroup.errorDescription)
            XCTAssertFalse(removedDevice.tasks.contains { $0.titleValue == title })
            let erasedGroup = try await removedDevice.mlsSessionForTesting?.group()
            XCTAssertNil(erasedGroup)
            try await assertLockedOut(retained, replay: replay, group: group)
            let authorization = try await retained.transportAuthorization()
            do {
                _ = try await relay.fetch(group: group, after: 0, limit: 32, authorization: authorization)
                XCTFail("relay served a removed writer after its final acknowledgement")
            } catch MLSRelayError.unauthorized {}
        }
    }

    func testLeaveIsCommittedByRemainingMembersAndLocksOutRetainedState() async throws {
        for size in [2, 3] {
            let names = (0..<size).map { "leave\(size)-\($0)" }
            let linked = try await linkedGroup(names)
            let leaver = linked[1]
            let group = try await groupID(linked[0])
            let retained = try await retainedState(of: names[1], engine: leaver, copy: "left\(size)")
            let replay = try await retainedState(of: names[1], engine: leaver, copy: "left\(size)-replay")
            XCTAssertTrue(leaver.addTask(title: "Kept by leaver \(size)"))
            leaver.unlinkAndKeepTasks()
            XCTAssertFalse(leaver.isPaired)
            XCTAssertTrue(leaver.tasks.contains { $0.titleValue == "Kept by leaver \(size)" })
            let remaining = linked.filter { $0 !== leaver }
            try await wait("removal committed") { remaining.allSatisfy { $0.linkedMemberCount == size - 1 && $0.isPaired } }
            let departures = root.appendingPathComponent(names[1]).appendingPathComponent(SyncEngine.departuresDirectoryName)
            try await wait("departure erased") {
                ((try? FileManager.default.contentsOfDirectory(atPath: departures.path)) ?? []).isEmpty
            }
            let title = "After leave \(size)"
            XCTAssertTrue(remaining[0].addTask(title: title))
            try await wait("remaining converge") {
                remaining.allSatisfy { $0.tasks.contains { $0.titleValue == title } } && remaining[0].pendingMailboxOperationCount == 0
            }
            XCTAssertFalse(leaver.tasks.contains { $0.titleValue == title })
            try await assertLockedOut(retained, replay: replay, group: group)
        }
    }

    func testLeaveKeepsRetryingUntilRelayIsReachable() async throws {
        let host = engine("retry-host")
        let leaver = engine("retry-leaver", departureRetryDelayNanoseconds: 1_000_000...20_000_000)
        try await pair(host, leaver)
        await relay.setAppendsUnavailable(true)
        leaver.unlinkAndKeepTasks()
        try await wait("initial attempts exhausted") { await self.relay.rejectedAppends > 12 }
        await relay.setAppendsUnavailable(false)
        try await wait("removal committed") { host.linkedMemberCount == 1 && host.isPaired }
        let departures = root.appendingPathComponent("retry-leaver").appendingPathComponent(SyncEngine.departuresDirectoryName)
        try await wait("departure erased") {
            ((try? FileManager.default.contentsOfDirectory(atPath: departures.path)) ?? []).isEmpty
        }
    }

    func testLeftInstallCanBeInvitedAgain() async throws {
        for size in [2, 3] {
            let names = (0..<size).map { "rejoin\(size)-\($0)" }
            let linked = try await linkedGroup(names)
            let host = linked[0]
            let leaver = linked[size - 1]
            leaver.unlinkAndKeepTasks()
            try await pair(host, leaver)
            try await wait("full membership again") { linked.allSatisfy { $0.linkedMemberCount == size && $0.isPaired } }
            let title = "Rejoined \(size)"
            XCTAssertTrue(leaver.addTask(title: title))
            try await wait("converged") { linked.allSatisfy { $0.tasks.contains { $0.titleValue == title } } }
        }
    }

    func testDeviceRemovalSurvivesRestartAndConcurrentRemoval() async throws {
        let names = ["durable-0", "durable-1", "durable-2"]
        let linked = try await linkedGroup(names)
        let target = linked[1]
        let other = linked[2]
        let group = try await groupID(other)
        let targetAuthorization = try await XCTUnwrapAsync(await target.mlsSessionForTesting?.client.transportAuthorization())
        await relay.setAppendsUnavailable(true)
        let device = try XCTUnwrap(linked[0].linkedDevices.first { $0.deviceID == target.localDeviceID })
        XCTAssertTrue(linked[0].removeDevice(device))
        XCTAssertEqual(linked[0].linkedDevices.first { $0.deviceID == target.localDeviceID }?.isRemovalPending, true)
        try await wait("removal blocked") { linked[0].mailboxState == .unavailable }
        await linked[0].stop()
        let restarted = engine(names[0])
        XCTAssertEqual(restarted.linkedDevices.first { $0.deviceID == target.localDeviceID }?.isRemovalPending, true)
        XCTAssertTrue(other.removeDevice(device))
        await relay.setAppendsUnavailable(false)
        try await wait("removed once") {
            restarted.linkedMemberCount == 2 && other.linkedMemberCount == 2 && !target.isPaired
        }
        XCTAssertFalse(restarted.linkedDevices.contains { $0.isRemovalPending })
        let writer = Data(SHA256.hash(data: targetAuthorization))
        let removals = await relay.log(group: group).filter { $0.delivery.removeWriter == writer }
        XCTAssertEqual(removals.count, 1)
        XCTAssertTrue(other.addTask(title: "After concurrent removal"))
        try await wait("converged") { restarted.tasks.contains { $0.titleValue == "After concurrent removal" } }
    }

    func testAddedMemberThatNeverJoinsIsRemoved() async throws {
        let host = engine("host", provisionalMemberWindow: 0.3)
        let invitation = try Invitation.from(url: try await invite(host), scheme: "gotsync-tests")
        let ghost = try MLSSession(
            directory: root.appendingPathComponent("ghost"),
            deviceID: Data(repeating: 0xA5, count: 16),
            secretStore: MemorySecretStore(),
            transport: relay
        )
        let connection = try await rendezvous.connect(route: invitation.route)
        let published = try await ghost.publishKeyPackage(pairingToken: invitation.pairingToken)
        let nonce = Data(repeating: 0x33, count: 32)
        var answered = false
        while !answered {
            guard case .binary(let frame) = try await connection.receive() else { continue }
            switch try PairingFrame.open(frame, for: invitation, from: .fromInviter) {
            case .offer:
                try await connection.send(PairingFrame.commitment(PairingSafetyCode.commitment(
                    groupID: try XCTUnwrap(invitation.groupID),
                    inviterFingerprint: try XCTUnwrap(invitation.inviterFingerprint),
                    keyPackageReference: published.reference,
                    joinerFingerprint: published.fingerprint,
                    joinerNonce: nonce
                )).seal(for: invitation, from: .fromJoiner))
            case .nonce:
                try await connection.send(PairingFrame.response(
                    keyPackageReference: published.reference, joinerFingerprint: published.fingerprint, joinerNonce: nonce
                ).seal(for: invitation, from: .fromJoiner))
                answered = true
            default:
                XCTFail("Unexpected frame")
            }
        }
        try await wait("safety code") { host.isHostApprovalPending }
        host.approveSafetyCode()
        try await wait("added") { host.isPaired && host.linkedMemberCount == 2 }
        await connection.cancel()
        try await wait("ghost removed") { host.linkedMemberCount == 1 }
        XCTAssertTrue(host.isPaired)
        XCTAssertEqual(host.linkedDevices.map(\.isCurrentDevice), [true])
        let reopened = engine("host")
        try await wait("lone member stays linked") { reopened.isPaired && reopened.phase == .synced }
    }

    func testSyncFilesAreExcludedFromBackup() async throws {
        let host = engine("backup-host")
        let joiner = engine("backup-joiner")
        XCTAssertTrue(host.addTask(title: "Local only"))
        try await pair(host, joiner)
        let directory = root.appendingPathComponent("backup-host")
        for file in ["replica-v1.json", ReplicationCheckpoint.filename] {
            let values = try directory.appendingPathComponent(file).resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true, file)
        }
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
