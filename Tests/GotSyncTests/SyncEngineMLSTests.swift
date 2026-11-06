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

    private func retiredOperations(_ count: Int) -> [TaskOperation] {
        (1...count).map {
            TaskOperation(
                originDeviceID: ReplicaDeviceID(uuid: UUID()),
                originSequence: 1,
                lamport: 1,
                taskID: UUID(),
                mutation: .create(title: "Retired \($0)", completed: false)
            )
        }
    }

    private func engineWithRetiredOrigins(_ name: String, count: Int) async throws -> SyncEngine {
        try await engineWithHistory(name, operations: retiredOperations(count))
    }

    private func engineWithHistory(_ name: String, operations: [TaskOperation]) async throws -> SyncEngine {
        let seeded = engine(name)
        let deviceID = try ReplicaDeviceID(bytes: seeded.localDeviceID)
        await seeded.stop()
        var replica = try TaskReplica(deviceID: deviceID)
        for batch in try OperationBatcher.batches(operations) {
            try replica.applyRemote(batch)
        }
        try ProtectedStorage.write(
            replica.atomicArchiveData(),
            to: root.appendingPathComponent("\(name)/replica-v1.json")
        )
        return engine(name)
    }

    func testReplacementDevicesBeyondTheGroupLimitKeepEveryTask() async throws {
        var host = engine("replacement-host")
        XCTAssertTrue(host.addTask(title: "Host task"))
        let replacements = 10
        for n in 1...replacements {
            let peer = engine("replacement-peer-\(n)")
            XCTAssertTrue(peer.addTask(title: "Peer \(n) task"))
            try await pair(host, peer)
            try await wait("replacement \(n) history") {
                host.tasks.count == n + 1 && peer.tasks.count == n + 1
                    && host.pendingMailboxOperationCount == 0 && peer.pendingMailboxOperationCount == 0
            }
            XCTAssertEqual(host.linkedMemberCount, 2)
            let peerFingerprint = try await fingerprint(peer)
            XCTAssertTrue(host.removeDevice(fingerprint: peerFingerprint))
            try await wait("replacement \(n) removed") { host.linkedMemberCount == 1 }
            await peer.stop()
        }
        let expected = Set(["Host task"] + (1...replacements).map { "Peer \($0) task" })
        XCTAssertEqual(Set(host.tasks.compactMap(\.titleValue)), expected)
        XCTAssertNil(host.errorMessage)
        XCTAssertFalse(host.isTaskHistoryAtCapacity)

        await host.stop()
        host = engine("replacement-host")
        XCTAssertEqual(Set(host.tasks.compactMap(\.titleValue)), expected)
        let latecomer = engine("replacement-latecomer")
        try await pair(host, latecomer)
        try await wait("latecomer catch-up") { Set(latecomer.tasks.compactMap(\.titleValue)) == expected }
        XCTAssertTrue(latecomer.addTask(title: "Latecomer task"))
        try await wait("latecomer contributes") { host.tasks.count == expected.count + 1 }
    }

    func testFullTaskHistoryRefusesAnotherDeviceBeforeLinking() async throws {
        let host = try await engineWithRetiredOrigins("capacity-host", count: ReplicaLimits.maxOrigins - 4)
        XCTAssertFalse(host.isTaskHistoryAtCapacity)
        let peer = engine("capacity-peer")
        try await pair(host, peer)
        XCTAssertTrue(peer.addTask(title: "Peer task"))
        XCTAssertTrue(host.addTask(title: "Host task"))
        try await wait("full history converges") {
            host.tasks.count == ReplicaLimits.maxOrigins - 2 && peer.tasks.count == ReplicaLimits.maxOrigins - 2
        }
        XCTAssertTrue(host.isTaskHistoryAtCapacity)
        XCTAssertTrue(peer.isTaskHistoryAtCapacity)

        host.createPrivateSync()
        XCTAssertNil(host.invitationURL)
        XCTAssertFalse(host.canCancelPairing)
        XCTAssertEqual(host.errorMessage, SyncError.taskHistoryAtCapacity.errorDescription)

        XCTAssertTrue(host.addTask(title: "Still syncing"))
        try await wait("linked devices keep syncing") {
            peer.tasks.contains { $0.titleValue == "Still syncing" }
        }
    }

    private func membersSharingOneFreeOriginSlot() async throws -> (SyncEngine, SyncEngine) {
        let host = try await engineWithRetiredOrigins("slot-host", count: ReplicaLimits.maxOrigins - 3)
        let second = engine("slot-second")
        try await pair(host, second)
        try await wait("second has history") {
            second.tasks.count == ReplicaLimits.maxOrigins - 3 && second.linkedMemberCount == 2
                && !second.awaitsReservationsForTesting
        }
        XCTAssertFalse(host.isTaskHistoryAtCapacity)
        XCTAssertFalse(second.isTaskHistoryAtCapacity)
        return (host, second)
    }

    private func pendingJoiners(
        _ host: SyncEngine,
        _ second: SyncEngine
    ) async throws -> (SyncEngine, SyncEngine) {
        let third = engine("slot-third")
        let fourth = engine("slot-fourth")
        third.joinPrivateSync(url: try await invite(host))
        fourth.joinPrivateSync(url: try await invite(second))
        try await wait("both safety codes") {
            host.isHostApprovalPending && second.isHostApprovalPending
                && third.safetyCode != nil && fourth.safetyCode != nil
        }
        return (third, fourth)
    }

    func testApprovalRechecksTaskHistoryAgainstMembersAddedMeanwhile() async throws {
        let (host, second) = try await membersSharingOneFreeOriginSlot()
        let (third, fourth) = try await pendingJoiners(host, second)

        host.approveSafetyCode()
        try await wait("third linked") { third.isPaired && host.linkedMemberCount == 3 }
        second.approveSafetyCode()
        try await wait("fourth refused") { fourth.phase == .failed && !second.canCancelPairing }
        XCTAssertEqual(second.lastPairingFailure, .taskHistoryAtCapacity)
        XCTAssertFalse(fourth.isPaired)
        XCTAssertEqual(fourth.errorMessage, SyncError.taskHistoryAtCapacity.errorDescription)

        XCTAssertTrue(third.addTask(title: "Last slot"))
        try await wait("last slot syncs") {
            [host, second].allSatisfy { engine in
                engine.linkedMemberCount == 3 && engine.tasks.contains { $0.titleValue == "Last slot" }
            }
        }
        XCTAssertTrue(host.isTaskHistoryAtCapacity)
        XCTAssertTrue(second.isTaskHistoryAtCapacity)
    }

    func testApprovalCountsUnappliedEditsOfAMemberRemovedMeanwhile() async throws {
        let (host, second) = try await membersSharingOneFreeOriginSlot()
        let late = engine("slot-late")
        late.joinPrivateSync(url: try await invite(host))
        try await wait("late safety code") { host.isHostApprovalPending && late.safetyCode != nil }
        let gate = SyncTestGate()
        host.inboxReadHookForTesting = { await gate.pause() }
        defer { gate.release() }

        let transient = engine("slot-transient")
        try await pair(second, transient)
        XCTAssertTrue(transient.addTask(title: "Transient task"))
        try await wait("transient uploaded while host drain is paused") {
            gate.isPaused && transient.pendingMailboxOperationCount == 0
                && second.tasks.contains { $0.titleValue == "Transient task" }
        }
        host.inboxReadHookForTesting = nil
        let transientFingerprint = try await fingerprint(transient)
        XCTAssertTrue(second.removeDevice(fingerprint: transientFingerprint))
        try await wait("transient removed") { second.linkedMemberCount == 2 }
        XCTAssertFalse(host.tasks.contains { $0.titleValue == "Transient task" })

        host.approveSafetyCode()
        try await wait("late refused") { late.phase == .failed && !host.canCancelPairing }
        XCTAssertEqual(host.lastPairingFailure, .taskHistoryAtCapacity)
        XCTAssertFalse(late.isPaired)
        gate.release()
        try await wait("host applies transient edit") {
            host.tasks.contains { $0.titleValue == "Transient task" } && host.linkedMemberCount == 2
        }
    }

    func testConcurrentApprovalsNeverAdmitPastTaskHistoryCapacity() async throws {
        let (host, second) = try await membersSharingOneFreeOriginSlot()
        let (third, fourth) = try await pendingJoiners(host, second)

        host.approveSafetyCode()
        second.approveSafetyCode()
        try await wait("both attempts end") {
            !host.canCancelPairing && !second.canCancelPairing
                && [third, fourth].allSatisfy { $0.isPaired || $0.phase == .failed }
        }
        try await wait("removals settle") {
            [host, second].allSatisfy { engine in
                engine.linkedDevices.allSatisfy { !$0.isRemovalPending } && engine.linkedMemberCount <= 3
            }
        }
        let linked = Set(host.linkedDevices.map(\.deviceID))
        XCTAssertTrue(linked.isSuperset(of: [host.localDeviceID, second.localDeviceID]))
        XCTAssertFalse(linked.contains(third.localDeviceID) && linked.contains(fourth.localDeviceID))
        XCTAssertLessThanOrEqual(linked.count, 3)
    }

    func testOriginSlotsCountEachRetainedOrPendingOriginOnceAndReserveMembers() {
        let origins = (1...3).map { _ in ReplicaDeviceID(uuid: UUID()) }
        XCTAssertEqual(SyncEngine.originSlots(retained: [], pending: [], memberCount: 0), 1)
        XCTAssertEqual(
            SyncEngine.originSlots(retained: [origins[0], origins[1]], pending: [origins[1], origins[2]], memberCount: 2),
            5
        )
        XCTAssertEqual(
            SyncEngine.originSlots(retained: origins, pending: Set(origins), memberCount: 1),
            4
        )
    }

    func testDisjointHistoriesBeyondCapacityAreRefusedBeforeAdmission() async throws {
        let host = try await engineWithRetiredOrigins("disjoint-host", count: 70)
        let joiner = try await engineWithRetiredOrigins("disjoint-joiner", count: 70)
        let hostTasks = Set(host.tasks.map(\.id))
        let joinerTasks = Set(joiner.tasks.map(\.id))
        XCTAssertFalse(host.isTaskHistoryAtCapacity)
        XCTAssertFalse(joiner.isTaskHistoryAtCapacity)

        let url = try await invite(host)
        let groupID = try XCTUnwrap(Invitation.from(url: url, scheme: "gotsync-tests").groupID)
        joiner.joinPrivateSync(url: url)
        try await wait("both refused") {
            host.phase == .failed && joiner.phase == .failed && !host.canCancelPairing && !joiner.canCancelPairing
        }
        XCTAssertEqual(host.errorMessage, SyncError.taskHistoryAtCapacity.errorDescription)
        XCTAssertEqual(joiner.errorMessage, SyncError.taskHistoryAtCapacity.errorDescription)
        XCTAssertFalse(host.isHostApprovalPending)
        XCTAssertFalse(host.isPaired)
        XCTAssertFalse(joiner.isPaired)
        let hostGroup = try await host.mlsSessionForTesting?.group()
        let joinerGroup = try await joiner.mlsSessionForTesting?.group()
        XCTAssertNil(hostGroup)
        XCTAssertNil(joinerGroup)
        let log = await relay.log(group: groupID)
        XCTAssertTrue(log.isEmpty)
        XCTAssertEqual(Set(host.tasks.map(\.id)), hostTasks)
        XCTAssertEqual(Set(joiner.tasks.map(\.id)), joinerTasks)
    }

    func testOverlappingHistoriesWithinCapacityPairAndConverge() async throws {
        let shared = retiredOperations(95)
        let host = try await engineWithHistory("overlap-host", operations: shared + retiredOperations(5))
        let joiner = try await engineWithHistory("overlap-joiner", operations: shared + retiredOperations(5))
        try await pair(host, joiner)
        try await wait("union converges") {
            host.tasks.count == 105 && Set(host.tasks.map(\.id)) == Set(joiner.tasks.map(\.id))
        }
        XCTAssertNil(host.errorMessage)
        XCTAssertNil(joiner.errorMessage)
    }

    func testPairingResponseCarriesCanonicalBoundedOriginInventory() throws {
        let invitation = try Invitation.generate(
            groupID: Data(repeating: 1, count: 32), inviterFingerprint: Data(repeating: 2, count: 32)
        )
        let origins = (1...ReplicaLimits.maxOrigins).map { _ in ReplicaDeviceID(uuid: UUID()) }
        let fixed = Data(repeating: 4, count: 32)
        let response = PairingFrame.response(
            keyPackageReference: fixed, joinerFingerprint: fixed, joinerNonce: fixed, origins: origins
        )
        let opened = try PairingFrame.open(response.seal(for: invitation, from: .fromJoiner), for: invitation, from: .fromJoiner)
        XCTAssertEqual(opened, .response(
            keyPackageReference: fixed, joinerFingerprint: fixed, joinerNonce: fixed, origins: origins.sorted()
        ))
        XCTAssertThrowsError(try PairingFrame.response(
            keyPackageReference: fixed, joinerFingerprint: fixed, joinerNonce: fixed, origins: [origins[0], origins[0]]
        ).seal(for: invitation, from: .fromJoiner))
        XCTAssertEqual(
            try PairingFrame.open(PairingFrame.historyFull.seal(for: invitation, from: .fromInviter), for: invitation, from: .fromInviter),
            .historyFull
        )

        let sorted = origins.sorted()
        let invalidBodies: [Data] = [
            fixed + fixed + fixed,
            fixed + fixed + fixed + Data([2]) + sorted[1].bytes + sorted[0].bytes,
            fixed + fixed + fixed + Data([2]) + sorted[0].bytes,
            fixed + fixed + fixed + Data([UInt8(ReplicaLimits.maxOrigins + 1)])
                + sorted.reduce(Data()) { $0 + $1.bytes } + Data(repeating: 0xFF, count: 16),
        ]
        for body in invalidBodies {
            XCTAssertThrowsError(try PairingFrame.open(sealed(body, kind: 2, key: invitation.responseKey), for: invitation, from: .fromJoiner))
        }
        XCTAssertThrowsError(try PairingFrame.open(sealed(Data([3]), kind: 3, key: invitation.offerKey), for: invitation, from: .fromInviter))
    }

    private func sealed(_ body: Data, kind: UInt8, key: SymmetricKey) throws -> Data {
        let associated = Data("\(ProtocolDomains.namespace)/mls-pairing-frame/v2".utf8) + Data([kind])
        return try Data([kind]) + ChaChaPoly.seal(body, using: key, authenticating: associated).combined
    }

    private func authorization(_ engine: SyncEngine) async throws -> Data {
        try await XCTUnwrapAsync(engine.mlsSessionForTesting).client.transportAuthorization()
    }

    private func settle(_ engines: [SyncEngine]) async throws {
        var last: [Int] = []
        var stable = 0
        for _ in 0..<150 {
            let snapshot = engines.flatMap { [$0.tasks.count, $0.pendingMailboxOperationCount, $0.linkedMemberCount] }
            stable = snapshot == last ? stable + 1 : 0
            last = snapshot
            if stable >= 20 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("devices did not settle")
    }

    private func assertAtMostOneJoinerLinked(
        _ joiners: [SyncEngine],
        localTasks: [Set<UUID>],
        members: [SyncEngine],
        group: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let linked = Set(members[0].linkedDevices.map(\.deviceID))
        let admitted = joiners.filter { $0.isPaired && linked.contains($0.localDeviceID) }
        XCTAssertLessThanOrEqual(admitted.count, 1, file: file, line: line)
        let sets = Set((members + admitted).map { Set($0.tasks.map(\.id)) })
        XCTAssertEqual(sets.count, 1, "linked devices diverge", file: file, line: line)
        for (joiner, tasks) in zip(joiners, localTasks) where !admitted.contains(where: { $0 === joiner }) {
            XCTAssertFalse(joiner.isPaired, file: file, line: line)
            XCTAssertTrue(Set(joiner.tasks.map(\.id)).isSuperset(of: tasks), file: file, line: line)
            let leftover = try await joiner.mlsSessionForTesting?.group()
            XCTAssertNil(leftover, "refused joiner kept MLS group state", file: file, line: line)
        }
        for member in members {
            XCTAssertEqual(member.linkedMemberCount, members.count + admitted.count, file: file, line: line)
        }
        let writers = await relay.activeWriterCount(group: group)
        XCTAssertEqual(writers, members.count + admitted.count, file: file, line: line)
    }

    private func linkedPairWithDisjointJoiners(
        _ prefix: String,
        shared: Int = 0,
        own: Int = 70
    ) async throws -> (SyncEngine, SyncEngine, SyncEngine, SyncEngine, Data) {
        let host = engine("\(prefix)-host")
        let second = engine("\(prefix)-second")
        try await pair(host, second)
        try await wait("second sees reservations") { !second.awaitsReservationsForTesting }
        let common = shared > 0 ? retiredOperations(shared) : []
        let first = try await engineWithHistory("\(prefix)-j1", operations: common + retiredOperations(own))
        let other = try await engineWithHistory("\(prefix)-j2", operations: common + retiredOperations(own))
        return (host, second, first, other, try await groupID(host))
    }

    private func approveConcurrently(
        host: SyncEngine, second: SyncEngine, first: SyncEngine, other: SyncEngine
    ) async throws {
        first.joinPrivateSync(url: try await invite(host))
        other.joinPrivateSync(url: try await invite(second))
        try await wait("both safety codes") {
            host.isHostApprovalPending && second.isHostApprovalPending && first.safetyCode != nil && other.safetyCode != nil
        }
        host.approveSafetyCode()
        second.approveSafetyCode()
        try await wait("both decisions final") {
            !host.canCancelPairing && !second.canCancelPairing
                && [first, other].allSatisfy { $0.isPaired || $0.phase == .failed }
        }
    }

    func testConcurrentInvitersAdmitAtMostOneDisjointJoiner() async throws {
        let (host, second, first, other, group) = try await linkedPairWithDisjointJoiners("cc")
        let local = [Set(first.tasks.map(\.id)), Set(other.tasks.map(\.id))]
        try await approveConcurrently(host: host, second: second, first: first, other: other)
        try await settle([host, second, first, other])
        try await assertAtMostOneJoinerLinked([first, other], localTasks: local, members: [host, second], group: group)
    }

    func testConcurrentInvitersCountJoinerWhoseHistoryIsHeld() async throws {
        let (host, second, first, other, group) = try await linkedPairWithDisjointJoiners("held")
        let local = [Set(first.tasks.map(\.id)), Set(other.tasks.map(\.id))]
        await relay.holdApplications(except: [try await authorization(host), try await authorization(second)])
        try await approveConcurrently(host: host, second: second, first: first, other: other)
        await relay.holdApplications(except: nil)
        for engine in [host, second, first, other] { engine.applicationDidBecomeActive() }
        try await settle([host, second, first, other])
        try await assertAtMostOneJoinerLinked([first, other], localTasks: local, members: [host, second], group: group)
    }

    func testInvitationAfterEarlierJoinerWelcomeCountsItsReservation() async throws {
        let (host, second, first, other, group) = try await linkedPairWithDisjointJoiners("seq")
        let local = [Set(first.tasks.map(\.id)), Set(other.tasks.map(\.id))]
        await relay.holdApplications(except: [try await authorization(host), try await authorization(second)])
        try await pair(host, first)
        try await wait("second sees first", timeout: .seconds(20)) { second.linkedMemberCount == 3 }
        other.joinPrivateSync(url: try await invite(second))
        try await wait("other refused") { other.phase == .failed && !second.canCancelPairing }
        XCTAssertEqual(other.errorMessage, SyncError.taskHistoryAtCapacity.errorDescription)
        await relay.holdApplications(except: nil)
        for engine in [host, second, first, other] { engine.applicationDidBecomeActive() }
        try await settle([host, second, first, other])
        try await assertAtMostOneJoinerLinked([first, other], localTasks: local, members: [host, second], group: group)
        XCTAssertTrue(first.isPaired)
    }

    func testFoundingReservationSurvivesRestartAndRefusesDisjointSecondJoiner() async throws {
        var host = engine("found-host")
        let first = try await engineWithRetiredOrigins("found-j1", count: 70)
        let other = try await engineWithRetiredOrigins("found-j2", count: 70)
        let local = [Set(first.tasks.map(\.id)), Set(other.tasks.map(\.id))]
        await relay.holdApplications(except: [try await authorization(host)])
        try await pair(host, first)
        let group = try await groupID(host)
        await host.stop()
        host = engine("found-host")
        try await wait("restarted host linked") { host.isPaired && host.linkedMemberCount == 2 }
        XCTAssertFalse(host.isTaskHistoryAtCapacity)
        other.joinPrivateSync(url: try await invite(host))
        try await wait("other refused") { other.phase == .failed && !host.canCancelPairing }
        XCTAssertEqual(other.errorMessage, SyncError.taskHistoryAtCapacity.errorDescription)
        await relay.holdApplications(except: nil)
        for engine in [host, first, other] { engine.applicationDidBecomeActive() }
        try await settle([host, first, other])
        try await assertAtMostOneJoinerLinked([first, other], localTasks: local, members: [host], group: group)
        XCTAssertTrue(first.isPaired)
        XCTAssertEqual(Set(host.tasks.map(\.id)), local[0])
    }

    func testConcurrentJoinersWithOverlappingHistoriesWithinCapacityBothLink() async throws {
        let (host, second, first, other, _) = try await linkedPairWithDisjointJoiners("overlap", shared: 50, own: 10)
        try await approveConcurrently(host: host, second: second, first: first, other: other)
        XCTAssertTrue(first.isPaired)
        XCTAssertTrue(other.isPaired)
        try await wait("four members converge", timeout: .seconds(20)) {
            [host, second, first, other].allSatisfy { $0.linkedMemberCount == 4 && $0.tasks.count == 70 }
        }
    }

    func testNewMemberInvitesOnlyAfterItsInviterSendsReservations() async throws {
        let host = engine("visible-host")
        XCTAssertTrue(host.addTask(title: "Host task"))
        let joiner = engine("visible-joiner")
        await relay.holdApplications(except: [try await authorization(host)])
        try await pair(host, joiner)
        XCTAssertTrue(joiner.awaitsReservationsForTesting)
        joiner.createPrivateSync()
        XCTAssertNil(joiner.invitationURL)
        XCTAssertEqual(joiner.errorMessage, SyncError.privateSyncUnreachable.errorDescription)
        await relay.holdApplications(except: nil)
        joiner.applicationDidBecomeActive()
        try await wait("snapshot arrives") { !joiner.awaitsReservationsForTesting }
        joiner.createPrivateSync()
        try await wait("joiner invites") { joiner.invitationURL != nil }
        XCTAssertEqual(joiner.tasks.map(\.titleValue), ["Host task"])
        joiner.cancelPairing(preserveLink: true)
    }

    func testEarlierClaimWinsWhenBothInvitersReserveBeforeEitherAdds() async throws {
        let (host, second, first, other, group) = try await linkedPairWithDisjointJoiners("forced")
        let local = [Set(first.tasks.map(\.id)), Set(other.tasks.map(\.id))]
        let hostGate = SyncTestGate()
        let secondGate = SyncTestGate()
        host.reservationHookForTesting = { await hostGate.pause() }
        second.reservationHookForTesting = { await secondGate.pause() }
        first.joinPrivateSync(url: try await invite(host))
        other.joinPrivateSync(url: try await invite(second))
        try await wait("both safety codes") {
            host.isHostApprovalPending && second.isHostApprovalPending && first.safetyCode != nil && other.safetyCode != nil
        }
        host.approveSafetyCode()
        second.approveSafetyCode()
        try await wait("both reserved") { hostGate.isPaused && secondGate.isPaused }
        let owners = [try await fingerprint(host), try await fingerprint(second)]
        let cursors = zip([host, second], owners).map { engine, owner in
            engine.reservationsForTesting.first { $0.owner == owner }?.cursor ?? 0
        }
        XCTAssertFalse(cursors.contains(0))
        hostGate.release()
        secondGate.release()
        try await wait("both decisions final") {
            !host.canCancelPairing && !second.canCancelPairing
                && [first, other].allSatisfy { $0.isPaired || $0.phase == .failed }
        }
        let winner = cursors[0] < cursors[1] ? first : other
        XCTAssertTrue(winner.isPaired)
        XCTAssertEqual((cursors[0] < cursors[1] ? second : host).lastPairingFailure, .taskHistoryAtCapacity)
        try await settle([host, second, first, other])
        try await assertAtMostOneJoinerLinked([first, other], localTasks: local, members: [host, second], group: group)
    }

    func testCancelledAdmissionReleasesItsReservation() async throws {
        let host = engine("cancel-host")
        let second = engine("cancel-second")
        try await pair(host, second)
        try await wait("second sees reservations") { !second.awaitsReservationsForTesting }
        let joiner = try await engineWithRetiredOrigins("cancel-joiner", count: 70)
        let gate = SyncTestGate()
        host.reservationHookForTesting = { await gate.pause() }
        joiner.joinPrivateSync(url: try await invite(host))
        try await wait("safety code") { host.isHostApprovalPending && joiner.safetyCode != nil }
        host.approveSafetyCode()
        try await wait("reserved") { gate.isPaused }
        let claim = try XCTUnwrap(host.reservationsForTesting.last)
        host.cancelPairing(preserveLink: true)
        gate.release()
        try await wait("released by its owner") {
            host.reservationsForTesting.allSatisfy { $0.cursor != claim.cursor || $0.released }
        }
        try await wait("others drop it") { !second.reservationsForTesting.contains { $0.cursor == claim.cursor } }
        XCTAssertFalse(host.isTaskHistoryAtCapacity)
        let writers = await relay.activeWriterCount(group: try await groupID(host))
        XCTAssertEqual(writers, 2)
    }

    func testFoundingClaimSurvivesCrashBetweenAddAndCheckpoint() async throws {
        var host = engine("crash-host")
        let first = try await engineWithRetiredOrigins("crash-j1", count: 70)
        let other = try await engineWithRetiredOrigins("crash-j2", count: 70)
        await relay.holdApplications(except: [try await authorization(host)])
        host.afterAddHookForTesting = { throw CancellationError() }
        first.joinPrivateSync(url: try await invite(host))
        try await wait("safety code") { host.isHostApprovalPending && first.safetyCode != nil }
        host.approveSafetyCode()
        try await wait("first joined") { first.isPaired }
        await host.stop()
        host = engine("crash-host")
        try await wait("recovered link") { host.isPaired && host.linkedMemberCount == 2 }
        let firstFingerprint = try await fingerprint(first)
        XCTAssertEqual(host.reservationsForTesting.map(\.member), [firstFingerprint])
        XCTAssertNil(host.membersWithUnknownHistoryForTesting)
        let directory = root.appendingPathComponent("crash-host")
        for filename in [ReplicationCheckpoint.foundingClaimsFilename, ReplicationCheckpoint.unreadableFoundingClaimsFilename] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path))
        }
        other.joinPrivateSync(url: try await invite(host))
        try await wait("other refused") { other.phase == .failed && !host.canCancelPairing }
        XCTAssertEqual(other.errorMessage, SyncError.taskHistoryAtCapacity.errorDescription)
        await relay.holdApplications(except: nil)
    }

    private func linkedPairWithLostClaim(
        _ prefix: String,
        thenUnavailable: Bool
    ) async throws -> (SyncEngine, SyncEngine, Data, UInt64) {
        let host = engine("\(prefix)-host")
        let second = engine("\(prefix)-second")
        try await pair(host, second)
        try await wait("second sees reservations") { !second.awaitsReservationsForTesting }
        let epoch = try await XCTUnwrapAsync(second.mlsSessionForTesting).epoch()
        let joiner = try await engineWithRetiredOrigins("\(prefix)-joiner", count: 63)
        joiner.joinPrivateSync(url: try await invite(host))
        try await wait("safety code") { host.isHostApprovalPending && joiner.safetyCode != nil }
        let joinerFingerprint = try await fingerprint(joiner)
        await relay.dropNextAppendResponse(thenUnavailable: thenUnavailable)
        host.approveSafetyCode()
        try await wait("pairing failed") { !host.canCancelPairing && joiner.phase == .failed }
        XCTAssertFalse(joiner.isPaired)
        return (host, second, joinerFingerprint, epoch)
    }

    private func assertLostClaimReleased(
        host: SyncEngine,
        second: SyncEngine,
        joiner: Data,
        epoch: UInt64,
        prefix: String
    ) async throws {
        for engine in [host, second] { engine.applicationDidBecomeActive() }
        try await wait("owner released the claim") {
            host.reservationAttemptsForTesting.isEmpty
                && !host.reservationsForTesting.contains { $0.member == joiner && !$0.released }
        }
        let released = try await XCTUnwrapAsync(host.mlsSessionForTesting).cursor()
        second.applicationDidBecomeActive()
        try await wait("second read the release") {
            let session = try await XCTUnwrapAsync(second.mlsSessionForTesting)
            let cursor = try await session.cursor()
            let unread = try await session.inbox()
            return cursor >= released && unread.isEmpty
        }
        let session = try await XCTUnwrapAsync(second.mlsSessionForTesting)
        let current = try await session.epoch()
        XCTAssertEqual(current, epoch)
        XCTAssertFalse(second.reservationsForTesting.contains { $0.member == joiner && !$0.released })
        let late = try await engineWithRetiredOrigins("\(prefix)-late", count: 63)
        try await pair(second, late)
        XCTAssertTrue(late.isPaired)
    }

    func testClaimWhoseAppendResponseWasLostIsReleased() async throws {
        let (host, second, joiner, epoch) = try await linkedPairWithLostClaim("lost", thenUnavailable: false)
        try await assertLostClaimReleased(host: host, second: second, joiner: joiner, epoch: epoch, prefix: "lost")
    }

    func testClaimWhoseAppendResponseWasLostIsReleasedAfterRestart() async throws {
        var (host, second, joiner, epoch) = try await linkedPairWithLostClaim("lost-restart", thenUnavailable: true)
        XCTAssertEqual(host.reservationAttemptsForTesting.map(\.member), [joiner])
        await host.stop()
        await relay.setAppendsUnavailable(false)
        host = engine("lost-restart-host")
        try await wait("host relinked") { host.isPaired }
        try await assertLostClaimReleased(host: host, second: second, joiner: joiner, epoch: epoch, prefix: "lost-restart")
    }

    func testClaimSentAfterItsPairingWasCancelledIsReleased() async throws {
        let host = engine("inflight-host")
        let second = engine("inflight-second")
        try await pair(host, second)
        try await wait("second sees reservations") { !second.awaitsReservationsForTesting }
        let epoch = try await XCTUnwrapAsync(second.mlsSessionForTesting).epoch()
        let joiner = try await engineWithRetiredOrigins("inflight-joiner", count: 63)
        let gate = SyncTestGate()
        host.reservationSendHookForTesting = { await gate.pause() }
        joiner.joinPrivateSync(url: try await invite(host))
        try await wait("safety code") { host.isHostApprovalPending && joiner.safetyCode != nil }
        let joinerFingerprint = try await fingerprint(joiner)
        host.approveSafetyCode()
        try await wait("attempt saved") { gate.isPaused }
        defer { gate.release() }
        host.cancelPairing(preserveLink: true)
        XCTAssertTrue(second.addTask(title: "Wakes the host"))
        host.applicationDidBecomeActive()
        try await wait("host synced meanwhile") { host.tasks.contains { $0.titleValue == "Wakes the host" } }
        XCTAssertEqual(host.reservationAttemptsForTesting.map(\.member), [joinerFingerprint])
        gate.release()
        try await assertLostClaimReleased(
            host: host, second: second, joiner: joinerFingerprint, epoch: epoch, prefix: "inflight"
        )
    }

    func testUnknownHistoryOfAMemberThatLeavesNoLongerBlocksInvitations() async throws {
        var host = engine("ghost-host")
        let first = try await engineWithRetiredOrigins("ghost-j1", count: 70)
        await relay.holdApplications(except: [try await authorization(host)])
        host.afterAddHookForTesting = { throw CancellationError() }
        first.joinPrivateSync(url: try await invite(host))
        try await wait("safety code") { host.isHostApprovalPending && first.safetyCode != nil }
        host.approveSafetyCode()
        try await wait("first joined") { first.isPaired }
        let firstFingerprint = try await fingerprint(first)
        await host.stop()
        let directory = root.appendingPathComponent("ghost-host")
        try Data("{damaged".utf8).write(to: directory.appendingPathComponent(ReplicationCheckpoint.foundingClaimsFilename))
        host = engine("ghost-host")
        try await wait("recovered link") { host.isPaired && host.linkedMemberCount == 2 }
        XCTAssertEqual(host.membersWithUnknownHistoryForTesting, [firstFingerprint])
        XCTAssertEqual(host.provisionalMembersForTesting, [firstFingerprint])
        XCTAssertTrue(host.removeDevice(fingerprint: firstFingerprint))
        try await wait("ghost removed") { host.linkedMemberCount == 1 && host.membersWithUnknownHistoryForTesting == nil }
        await relay.holdApplications(except: nil)
        let other = engine("ghost-j2")
        try await pair(host, other)
        XCTAssertTrue(other.isPaired)
    }

    /// The host's Add lands and its first joiner joins, but the answer
    /// reaches the host only after it gave up on the pairing.
    private func foundingHostWithLostAdd(
        _ prefix: String,
        offline: Bool
    ) async throws -> (host: SyncEngine, first: SyncEngine, other: SyncEngine, local: [Set<UUID>]) {
        let host = engine("\(prefix)-host")
        let first = try await engineWithRetiredOrigins("\(prefix)-j1", count: 70)
        let other = try await engineWithRetiredOrigins("\(prefix)-j2", count: 70)
        let local = [Set(first.tasks.map(\.id)), Set(other.tasks.map(\.id))]
        await relay.holdApplications(except: [try await authorization(host)])
        var armed = true
        host.reservationHookForTesting = { [relay] in
            guard armed else { return }
            armed = false
            await relay?.dropNextAppendResponse(held: true)
        }
        first.joinPrivateSync(url: try await invite(host))
        try await wait("safety code") { host.isHostApprovalPending && first.safetyCode != nil }
        host.approveSafetyCode()
        do {
            try await wait("first joined") { first.isPaired }
        } catch {
            await relay.releaseDroppedResponse()
            throw error
        }
        if offline {
            await relay.setOffline(try await authorization(host), true)
        }
        await relay.releaseDroppedResponse()
        try await wait("host gave up") { !host.canCancelPairing }
        return (host, first, other, local)
    }

    private func assertSecondDisjointJoinerRefused(
        host: SyncEngine,
        first: SyncEngine,
        other: SyncEngine,
        local: [Set<UUID>],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        other.joinPrivateSync(url: try await invite(host))
        try await wait("other refused") { other.phase == .failed && !host.canCancelPairing }
        XCTAssertEqual(other.errorMessage, SyncError.taskHistoryAtCapacity.errorDescription, file: file, line: line)
        await relay.holdApplications(except: nil)
        for engine in [host, first, other] { engine.applicationDidBecomeActive() }
        try await settle([host, first, other])
        XCTAssertLessThanOrEqual(Set(host.tasks.map(\.id)).count, ReplicaLimits.maxOrigins, file: file, line: line)
        let group = try await groupID(host)
        try await assertAtMostOneJoinerLinked(
            [first, other], localTasks: local, members: [host], group: group, file: file, line: line
        )
        XCTAssertTrue(first.isPaired, file: file, line: line)
    }

    func testFoundingAddWhoseAnswerWasLostCountsBeforeTheNextJoiner() async throws {
        let (host, first, other, local) = try await foundingHostWithLostAdd("lostadd", offline: false)
        try await wait("host adopted the group") { host.isPaired && host.linkedMemberCount == 2 }
        let firstFingerprint = try await fingerprint(first)
        XCTAssertTrue(host.reservationsForTesting.contains { $0.member == firstFingerprint })
        try await assertSecondDisjointJoinerRefused(host: host, first: first, other: other, local: local)
    }

    func testFoundingInviterFailsClosedWhileItsLastAddIsUnsettled() async throws {
        let (host, first, other, local) = try await foundingHostWithLostAdd("lostadd-offline", offline: true)
        let journal = root.appendingPathComponent("lostadd-offline-host/\(ReplicationCheckpoint.foundingClaimsFilename)")
        XCTAssertFalse(host.isPaired)
        host.createPrivateSync()
        try await wait("invitation refused") { host.lastPairingFailure != nil && !host.canCancelPairing }
        XCTAssertEqual(host.lastPairingFailure, .privateSyncUnreachable)
        XCTAssertNil(host.invitationURL)
        XCTAssertFalse(host.isPaired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        await relay.setOffline(try await authorization(host), false)
        try await assertSecondDisjointJoinerRefused(host: host, first: first, other: other, local: local)
    }

    func testUnpairedHostAdoptsItsGroupAndAdmitsAFittingJoinerInTheSameAttempt() async throws {
        let (host, first, _, _) = try await foundingHostWithLostAdd("adopt", offline: true)
        XCTAssertFalse(host.isPaired)
        await relay.setOffline(try await authorization(host), false)
        let small = try await engineWithRetiredOrigins("adopt-small", count: 5)
        let url = try await invite(host)
        XCTAssertTrue(host.isPaired)
        small.joinPrivateSync(url: url)
        try await wait("safety code") { host.isHostApprovalPending && small.safetyCode != nil }
        host.approveSafetyCode()
        try await wait("small joined") { small.isPaired && !host.canCancelPairing }
        await relay.holdApplications(except: nil)
        for engine in [host, first, small] { engine.applicationDidBecomeActive() }
        try await wait("all three linked") { [host, first, small].allSatisfy { $0.linkedMemberCount == 3 } }
        try await settle([host, first, small])
        XCTAssertEqual(Set(host.tasks.map(\.id)), Set(first.tasks.map(\.id)).union(small.tasks.map(\.id)))
    }

    func testUnpairedHostThatAdoptedItsGroupKeepsItWhenTheNextJoinerIsDeclined() async throws {
        let (host, first, other, _) = try await foundingHostWithLostAdd("adopt-decline", offline: true)
        await relay.setOffline(try await authorization(host), false)
        other.joinPrivateSync(url: try await invite(host))
        try await wait("refused or awaiting approval") {
            (host.isHostApprovalPending && other.safetyCode != nil) || (other.phase == .failed && !host.canCancelPairing)
        }
        if host.isHostApprovalPending {
            host.cancelPairing()
        }
        try await wait("pairing ended") { !host.canCancelPairing }
        XCTAssertTrue(host.isPaired)
        XCTAssertFalse(other.isPaired)
        let firstFingerprint = try await fingerprint(first)
        try await wait("first still linked") {
            let members = try await XCTUnwrapAsync(host.mlsSessionForTesting).members()
            return members.contains { $0.fingerprint == firstFingerprint } && host.linkedMemberCount == 2
        }
        XCTAssertTrue(first.isPaired)
    }

    func testJoinerWithoutCheckpointCannotInviteBeforeItsSnapshot() async throws {
        let host = engine("intent-host")
        var joiner = engine("intent-joiner")
        try await pair(host, joiner)
        await relay.holdApplications(except: [try await authorization(joiner)])
        await joiner.stop()
        let directory = root.appendingPathComponent("intent-joiner")
        let checkpoint = directory.appendingPathComponent(ReplicationCheckpoint.filename)
        var saved = try XCTUnwrap(ReplicationCheckpoint.load(from: checkpoint))
        saved.reservationsVisible = false
        try saved.save(to: directory.appendingPathComponent(ReplicationCheckpoint.joinIntentFilename))
        try FileManager.default.removeItem(at: checkpoint)
        joiner = engine("intent-joiner")
        joiner.createPrivateSync()
        try await wait("invitation refused") {
            joiner.invitationURL == nil && !joiner.canCancelPairing && joiner.isPaired
                && (joiner.lastPairingFailure == .privateSyncUnreachable
                    || joiner.errorMessage == SyncError.privateSyncUnreachable.errorDescription)
        }
        XCTAssertTrue(joiner.awaitsReservationsForTesting)
        await relay.holdApplications(except: nil)
    }

    func testFoundingInviterRemovedAfterItsLostAddStartsAFreshGroup() async throws {
        let (host, first, _, _) = try await foundingHostWithLostAdd("removed", offline: true)
        await relay.holdApplications(except: nil)
        let hostFingerprint = try await fingerprint(host)
        try await wait("first sees host") { first.linkedDevices.count == 2 }
        XCTAssertTrue(first.removeDevice(fingerprint: hostFingerprint))
        try await wait("host removed") {
            let members = try await XCTUnwrapAsync(first.mlsSessionForTesting).members()
            return members.count == 1
        }
        await relay.setOffline(try await authorization(host), false)
        host.createPrivateSync()
        try await wait("invitation refused") { host.lastPairingFailure != nil && !host.canCancelPairing }
        XCTAssertEqual(host.lastPairingFailure, .removedFromGroup)
        let group = try await host.mlsSessionForTesting?.group()
        XCTAssertNil(group)
        let fresh = engine("removed-fresh")
        try await pair(host, fresh)
        XCTAssertTrue(fresh.isPaired)
    }

    func testDamagedClaimsOfALostFoundingAddBlockInvitationsUntilTheMemberReports() async throws {
        let (host, first, other, local) = try await foundingHostWithLostAdd("lostadd-damaged", offline: true)
        let directory = root.appendingPathComponent("lostadd-damaged-host")
        let damaged = Data("{damaged".utf8)
        try damaged.write(to: directory.appendingPathComponent(ReplicationCheckpoint.foundingClaimsFilename))
        await relay.setOffline(try await authorization(host), false)
        host.createPrivateSync()
        try await wait("invitation refused") { host.lastPairingFailure != nil && !host.canCancelPairing }
        XCTAssertEqual(host.lastPairingFailure, .privateSyncUnreachable)
        XCTAssertTrue(host.isPaired)
        let firstFingerprint = try await fingerprint(first)
        XCTAssertEqual(host.membersWithUnknownHistoryForTesting, [firstFingerprint])
        let aside = directory.appendingPathComponent(ReplicationCheckpoint.unreadableFoundingClaimsFilename)
        XCTAssertEqual(try Data(contentsOf: aside), damaged)
        await relay.holdApplications(except: nil)
        for engine in [host, first] { engine.applicationDidBecomeActive() }
        try await wait("first reported its history") { host.membersWithUnknownHistoryForTesting == nil }
        try await assertSecondDisjointJoinerRefused(host: host, first: first, other: other, local: local)
    }

    func testDamagedClaimsOfALostFoundingAddAreRecoveredOnRestart() async throws {
        var (host, first, other, local) = try await foundingHostWithLostAdd("lostadd-restart", offline: true)
        await host.stop()
        let directory = root.appendingPathComponent("lostadd-restart-host")
        try Data("{damaged".utf8).write(to: directory.appendingPathComponent(ReplicationCheckpoint.foundingClaimsFilename))
        await relay.setOffline(try await authorization(host), false)
        host = engine("lostadd-restart-host")
        try await wait("host adopted the group") { host.isPaired && host.linkedMemberCount == 2 }
        let firstFingerprint = try await fingerprint(first)
        XCTAssertEqual(host.membersWithUnknownHistoryForTesting, [firstFingerprint])
        await relay.holdApplications(except: nil)
        for engine in [host, first] { engine.applicationDidBecomeActive() }
        try await wait("first reported its history") { host.membersWithUnknownHistoryForTesting == nil }
        try await assertSecondDisjointJoinerRefused(host: host, first: first, other: other, local: local)
    }

    func testUnreadableFoundingClaimsBlockAdmissionUntilMembersReportHistory() async throws {
        var host = engine("unreadable-host")
        let first = try await engineWithRetiredOrigins("unreadable-j1", count: 70)
        let other = try await engineWithRetiredOrigins("unreadable-j2", count: 70)
        let local = [Set(first.tasks.map(\.id)), Set(other.tasks.map(\.id))]
        await relay.holdApplications(except: [try await authorization(host)])
        host.afterAddHookForTesting = { throw CancellationError() }
        first.joinPrivateSync(url: try await invite(host))
        try await wait("safety code") { host.isHostApprovalPending && first.safetyCode != nil }
        host.approveSafetyCode()
        try await wait("first joined") { first.isPaired }
        let group = try await groupID(host)
        await host.stop()
        let directory = root.appendingPathComponent("unreadable-host")
        let journal = directory.appendingPathComponent(ReplicationCheckpoint.foundingClaimsFilename)
        let aside = directory.appendingPathComponent(ReplicationCheckpoint.unreadableFoundingClaimsFilename)
        let damaged = Data("{damaged".utf8)
        try damaged.write(to: journal)
        host = engine("unreadable-host")
        try await wait("recovered link") { host.isPaired && host.linkedMemberCount == 2 }
        let firstFingerprint = try await fingerprint(first)
        XCTAssertEqual(host.membersWithUnknownHistoryForTesting, [firstFingerprint])
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertEqual(try Data(contentsOf: aside), damaged)
        host.createPrivateSync()
        XCTAssertNil(host.invitationURL)
        XCTAssertEqual(host.errorMessage, SyncError.privateSyncUnreachable.errorDescription)
        await relay.holdApplications(except: nil)
        for engine in [host, first] { engine.applicationDidBecomeActive() }
        try await wait("first reported its history") { host.membersWithUnknownHistoryForTesting == nil }
        other.joinPrivateSync(url: try await invite(host))
        try await wait("other refused") { other.phase == .failed && !host.canCancelPairing }
        XCTAssertEqual(other.errorMessage, SyncError.taskHistoryAtCapacity.errorDescription)
        try await settle([host, first, other])
        try await assertAtMostOneJoinerLinked([first, other], localTasks: local, members: [host], group: group)
        XCTAssertTrue(first.isPaired)
    }

    func testUnreadableFoundingClaimsBeforeAnyAddAreSetAside() async throws {
        let host = engine("aside-host")
        let joiner = engine("aside-joiner")
        let directory = root.appendingPathComponent("aside-host")
        let damaged = Data("{damaged".utf8)
        try damaged.write(to: directory.appendingPathComponent(ReplicationCheckpoint.foundingClaimsFilename))
        try await pair(host, joiner)
        XCTAssertTrue(joiner.isPaired)
        XCTAssertNil(host.membersWithUnknownHistoryForTesting)
        let aside = directory.appendingPathComponent(ReplicationCheckpoint.unreadableFoundingClaimsFilename)
        XCTAssertEqual(try Data(contentsOf: aside), damaged)
        let joinerFingerprint = try await fingerprint(joiner)
        XCTAssertEqual(host.reservationsForTesting.map(\.member), [joinerFingerprint])
    }

    func testDrainDoesNotOverwriteAdmissionStateSavedMeanwhile() async throws {
        let host = engine("overwrite-host")
        let second = engine("overwrite-second")
        try await pair(host, second)
        try await wait("second sees reservations") { !second.awaitsReservationsForTesting }
        let joiner = try await engineWithRetiredOrigins("overwrite-joiner", count: 5)
        joiner.joinPrivateSync(url: try await invite(host))
        try await wait("safety code") { host.isHostApprovalPending && joiner.safetyCode != nil }
        await relay.holdApplications(except: [try await authorization(host), try await authorization(second)])
        let gate = SyncTestGate()
        host.inboxReadHookForTesting = { await gate.pause() }
        XCTAssertTrue(second.addTask(title: "Fills the host inbox"))
        try await wait("host drain paused") { gate.isPaused }
        host.inboxReadHookForTesting = nil
        host.approveSafetyCode()
        try await wait("joiner admitted") { joiner.isPaired && !host.canCancelPairing }
        let joinerFingerprint = try await fingerprint(joiner)
        gate.release()
        try await wait("drain finished") { host.tasks.contains { $0.titleValue == "Fills the host inbox" } }
        XCTAssertTrue(host.reservationsForTesting.contains { $0.member == joinerFingerprint })
        XCTAssertTrue(host.provisionalMembersForTesting.contains(joinerFingerprint))
        await relay.holdApplications(except: nil)
    }

    func testNewMemberAsksAnotherMemberWhenItsProviderLeaves() async throws {
        let host = engine("leaving-host")
        let second = engine("leaving-second")
        try await pair(host, second)
        try await wait("second sees reservations") { !second.awaitsReservationsForTesting }
        let joiner = engine("leaving-joiner")
        await relay.holdApplications(except: [try await authorization(host), try await authorization(second)])
        try await pair(host, joiner)
        try await wait("second sees joiner") { second.linkedMemberCount == 3 }
        let hostFingerprint = try await fingerprint(host)
        XCTAssertTrue(second.removeDevice(fingerprint: hostFingerprint))
        try await wait("provider removed") { second.linkedMemberCount == 2 }
        XCTAssertTrue(joiner.awaitsReservationsForTesting)
        await relay.holdApplications(except: nil)
        joiner.applicationDidBecomeActive()
        try await wait("second provides reservations", timeout: .seconds(20)) { !joiner.awaitsReservationsForTesting }
    }

    func testRecoveredJoinerStillWaitsForReservations() async throws {
        let host = engine("recover-host")
        XCTAssertTrue(host.addTask(title: "Host task"))
        await relay.failNextWelcomeAcknowledgement()
        var joiner = engine("recover-joiner")
        joiner.joinPrivateSync(url: try await invite(host))
        try await wait("safety code") { host.isHostApprovalPending && joiner.safetyCode != nil }
        await relay.holdApplications(except: [try await authorization(host)])
        host.approveSafetyCode()
        try await wait("interrupted after admission") { joiner.phase == .failed }
        await joiner.stop()
        joiner = engine("recover-joiner")
        try await wait("recovered membership") { joiner.isPaired }
        XCTAssertTrue(joiner.awaitsReservationsForTesting)
        joiner.createPrivateSync()
        XCTAssertNil(joiner.invitationURL)
        await relay.holdApplications(except: nil)
        joiner.applicationDidBecomeActive()
        try await wait("snapshot arrives") { !joiner.awaitsReservationsForTesting }
    }

    func testExpiredLeaseCannotAuthorizeALateAdd() async throws {
        let (host, second, first, other, group) = try await linkedPairWithDisjointJoiners("lease")
        let local = [Set(first.tasks.map(\.id)), Set(other.tasks.map(\.id))]
        let gate = SyncTestGate()
        host.reservationHookForTesting = { await gate.pause() }
        defer { gate.release() }
        first.joinPrivateSync(url: try await invite(host))
        try await wait("safety code") { host.isHostApprovalPending && first.safetyCode != nil }
        host.approveSafetyCode()
        try await wait("host reserved") { gate.isPaused }
        host.reservationHookForTesting = nil
        let commitsPerCycle = 2
        for cycle in 1...Int(OriginReservation.leaseEpochs) / commitsPerCycle {
            let transient = engine("lease-transient-\(cycle)")
            try await pair(second, transient)
            let transientFingerprint = try await fingerprint(transient)
            XCTAssertTrue(second.removeDevice(fingerprint: transientFingerprint))
            try await wait("transient \(cycle) removed") { second.linkedMemberCount == 2 }
            await transient.stop()
        }
        await relay.holdApplications(except: [try await authorization(host), try await authorization(second)])
        try await pair(second, other)
        gate.release()
        try await wait("host attempt ends") { !host.canCancelPairing && (first.isPaired || first.phase == .failed) }
        XCTAssertFalse(first.isPaired)
        XCTAssertEqual(host.lastPairingFailure, .invalidPairMessage)
        await relay.holdApplications(except: nil)
        for engine in [host, second, first, other] { engine.applicationDidBecomeActive() }
        try await settle([host, second, first, other])
        try await assertAtMostOneJoinerLinked([first, other], localTasks: local, members: [host, second], group: group)
        XCTAssertTrue(other.isPaired)
    }

    func testReplacementProviderMustHoldItsOwnReservations() async throws {
        let (host, second, first, other, _) = try await linkedPairWithDisjointJoiners("replace")
        await relay.holdApplications(except: [try await authorization(host), try await authorization(second)])
        try await pair(host, first)
        let late = engine("replace-late")
        let later = engine("replace-later")
        try await pair(host, late)
        try await pair(host, later)
        XCTAssertTrue(late.awaitsReservationsForTesting)
        XCTAssertTrue(later.awaitsReservationsForTesting)
        let hostFingerprint = try await fingerprint(host)
        XCTAssertTrue(second.removeDevice(fingerprint: hostFingerprint))
        try await wait("host removed") { second.linkedMemberCount == 4 }
        await relay.holdApplications(except: [
            try await authorization(second), try await authorization(late), try await authorization(later),
        ])
        for engine in [second, late, later] { engine.applicationDidBecomeActive() }
        try await wait("complete snapshots", timeout: .seconds(30)) {
            !late.awaitsReservationsForTesting && !later.awaitsReservationsForTesting
        }
        let firstFingerprint = try await fingerprint(first)
        XCTAssertTrue(late.reservationsForTesting.contains { $0.member == firstFingerprint })
        XCTAssertTrue(later.reservationsForTesting.contains { $0.member == firstFingerprint })
        other.joinPrivateSync(url: try await invite(late))
        try await wait("other refused") { other.phase == .failed && !late.canCancelPairing }
        XCTAssertEqual(late.lastPairingFailure, .taskHistoryAtCapacity)
        await relay.holdApplications(except: nil)
    }

    func testUnsentReplacementRequestIsRetriedAfterRestart() async throws {
        let host = engine("unsent-host")
        let second = engine("unsent-second")
        try await pair(host, second)
        try await wait("second sees reservations") { !second.awaitsReservationsForTesting }
        let gate = SyncTestGate()
        host.inboxReadHookForTesting = { await gate.pause() }
        defer { gate.release() }
        var joiner = engine("unsent-joiner")
        try await pair(host, joiner)
        try await wait("host stops answering") { gate.isPaused }
        try await wait("joiner announced") { joiner.phase == .synced }
        XCTAssertTrue(joiner.awaitsReservationsForTesting)
        joiner.beforeReservationRequestHookForTesting = { throw CancellationError() }
        let hostFingerprint = try await fingerprint(host)
        let secondFingerprint = try await fingerprint(second)
        XCTAssertTrue(second.removeDevice(fingerprint: hostFingerprint))
        try await wait("replacement saved but not sent") { joiner.reservationsProviderForTesting == secondFingerprint }
        await joiner.stop()
        joiner = engine("unsent-joiner")
        try await wait("request retried", timeout: .seconds(20)) {
            joiner.isPaired && !joiner.awaitsReservationsForTesting
        }
    }

    func testReservationMergeKeepsOrderOwnershipAndLocalEvidence() {
        let owner = Data(repeating: 1, count: 32)
        let stranger = Data(repeating: 2, count: 32)
        let member = Data(repeating: 3, count: 32)
        let origins = (1...3).map { _ in ReplicaDeviceID(uuid: UUID()) }.sorted()
        func update(_ cursor: UInt64, _ sender: Data, _ message: ReplicationMessage) -> SyncEngine.ReservationUpdate {
            SyncEngine.ReservationUpdate(cursor: cursor, sender: sender, message: message)
        }
        let claimed = SyncEngine.merge([
            update(9, owner, .reservation(member: member, origins: origins, epoch: 4)),
            update(5, owner, .reservation(member: stranger, origins: [origins[0]], epoch: 4)),
            update(10, stranger, .release(member: member, reservation: 9)),
            update(11, owner, .release(member: member, reservation: 5)),
        ], into: [], snapshotsFor: nil)
        XCTAssertEqual(claimed.map(\.cursor), [5, 9])
        XCTAssertEqual(claimed.map(\.released), [false, false])
        XCTAssertEqual(claimed[1].owner, owner)
        XCTAssertEqual(claimed[1].origins, origins)

        let released = SyncEngine.merge(
            [update(12, owner, .release(member: member, reservation: 9))], into: claimed, snapshotsFor: nil
        )
        XCTAssertEqual(released.map(\.released), [false, true])
        var stale = claimed
        stale.append(OriginReservation(member: stranger, owner: owner, origins: [], epoch: 1, cursor: 30))
        let snapshot = SyncEngine.merge(
            [update(20, owner, .reservations(stale, overflowed: false, for: member))], into: released, snapshotsFor: member
        )
        XCTAssertEqual(snapshot.map(\.cursor), [5, 9])
        XCTAssertEqual(snapshot.map(\.released), [false, true])
        XCTAssertEqual(
            SyncEngine.merge([update(20, owner, .reservations(stale, overflowed: false, for: member))], into: [], snapshotsFor: nil),
            []
        )
        XCTAssertEqual(
            SyncEngine.merge([update(20, owner, .reservations(stale, overflowed: false, for: stranger))], into: [], snapshotsFor: member),
            []
        )

        let tombstoned = SyncEngine.merge([
            update(12, owner, .release(member: member, reservation: 9)),
            update(20, owner, .reservations(claimed, overflowed: false, for: member)),
        ], into: [], snapshotsFor: member)
        XCTAssertEqual(tombstoned.first { $0.cursor == 9 }?.released, true)
        let later = SyncEngine.merge(
            [update(20, owner, .reservations(claimed, overflowed: false, for: member))],
            into: SyncEngine.merge([update(12, owner, .release(member: member, reservation: 9))], into: [], snapshotsFor: member),
            snapshotsFor: member
        )
        XCTAssertEqual(later.first { $0.cursor == 9 }?.released, true)
    }

    func testReservationLeaseUsesEpochsAndNeverLapsesForMembers() {
        let member = Data(repeating: 3, count: 32)
        let origins = (1...2).map { _ in ReplicaDeviceID(uuid: UUID()) }.sorted()
        var claim = OriginReservation(member: member, owner: member, origins: origins, epoch: 10, cursor: 1)
        let lastEpoch = 10 + OriginReservation.leaseEpochs - 1
        XCTAssertTrue(claim.allowsAdd(atEpoch: lastEpoch))
        XCTAssertFalse(claim.allowsAdd(atEpoch: lastEpoch + 1))
        XCTAssertTrue(claim.isActive(roster: [], epoch: lastEpoch))
        XCTAssertFalse(claim.isActive(roster: [], epoch: lastEpoch + 1))
        XCTAssertTrue(claim.isActive(roster: [member], epoch: 1_000))
        claim.released = true
        XCTAssertFalse(claim.isActive(roster: [], epoch: 10))
        XCTAssertTrue(claim.isActive(roster: [member], epoch: 10))

        func prune(_ entries: [OriginReservation], roster: Set<Data>, epoch: UInt64, retained: Set<ReplicaDeviceID>, keepReleases: Bool = false) -> [OriginReservation] {
            SyncEngine.prune(entries, roster: roster, epoch: epoch, retained: retained, keepReleases: keepReleases).kept
        }
        let pending = OriginReservation(member: member, owner: member, origins: origins, epoch: 10, cursor: 1)
        XCTAssertEqual(prune([pending], roster: [], epoch: lastEpoch, retained: []), [pending])
        XCTAssertEqual(prune([pending], roster: [], epoch: lastEpoch + 1, retained: []), [])
        let joined = prune([pending], roster: [member], epoch: 1_000, retained: [origins[0]])
        XCTAssertEqual(joined.map(\.admitted), [true])
        XCTAssertEqual(prune(joined, roster: [member], epoch: 1_000, retained: Set(origins)), [])
        XCTAssertEqual(prune(joined, roster: [], epoch: 1_000, retained: []), [])
        var tombstone = pending
        tombstone.released = true
        XCTAssertEqual(prune([tombstone], roster: [], epoch: 10, retained: [], keepReleases: true), [tombstone])
        XCTAssertEqual(prune([tombstone], roster: [], epoch: 10, retained: []), [])

        func claims(_ count: Int) -> [OriginReservation] {
            (1...UInt64(count)).map {
                OriginReservation(member: Data(repeating: UInt8($0 % 250), count: 32), owner: member, origins: [], epoch: 10, cursor: $0)
            }
        }
        let active = SyncEngine.prune(claims(OriginReservation.maximumActive + 1), roster: [], epoch: 10, retained: [], keepReleases: false)
        XCTAssertEqual(active.kept.count, OriginReservation.maximumActive + 1)
        XCTAssertFalse(active.overflowed)
        let flood = SyncEngine.prune(claims(OriginReservation.maximumStored + 1), roster: [], epoch: 10, retained: [], keepReleases: false)
        XCTAssertEqual(flood.kept.count, OriginReservation.maximumStored)
        XCTAssertTrue(flood.overflowed)
    }

    func testReservationMessagesAreCanonicalAndBounded() throws {
        let member = Data(repeating: 3, count: 32)
        let origins = (1...ReplicaLimits.maxOrigins).map { _ in ReplicaDeviceID(uuid: UUID()) }
        let reservation = ReplicationMessage.reservation(member: member, origins: origins, epoch: 2)
        XCTAssertEqual(try ReplicationMessage.decode(reservation.encoded()), reservation)
        XCTAssertEqual(reservation.origins, origins.sorted())
        let release = ReplicationMessage.release(member: member, reservation: 7)
        XCTAssertEqual(try ReplicationMessage.decode(release.encoded()), release)
        let snapshot = ReplicationMessage.reservations(
            [OriginReservation(member: member, owner: member, origins: origins.sorted(), epoch: 2, cursor: 7)],
            overflowed: true, for: member
        )
        XCTAssertEqual(try ReplicationMessage.decode(snapshot.encoded()), snapshot)

        var unsorted = reservation
        unsorted.origins = origins.sorted().reversed()
        var oversized = reservation
        oversized.origins = (origins + [ReplicaDeviceID(uuid: UUID())]).sorted()
        var unbound = release
        unbound.reservation = nil
        var anonymous = snapshot
        anonymous.member = nil
        for message in [unsorted, oversized, unbound, anonymous] {
            XCTAssertThrowsError(try ReplicationMessage.decode(ReplicaCanonicalJSON.encode(message)))
        }
    }

    func testJoinerWithFullTaskHistoryIsRefusedBeforeLinking() async throws {
        let joiner = try await engineWithRetiredOrigins("full-joiner", count: ReplicaLimits.maxOrigins - 1)
        XCTAssertTrue(joiner.isTaskHistoryAtCapacity)
        let host = engine("roomy-host")
        let url = try await invite(host)

        joiner.joinPrivateSync(url: url)
        XCTAssertEqual(joiner.phase, .failed)
        XCTAssertEqual(joiner.errorMessage, SyncError.taskHistoryAtCapacity.errorDescription)
        XCTAssertFalse(joiner.canCancelPairing)
        XCTAssertNil(joiner.safetyCode)
        XCTAssertFalse(joiner.isPaired)
        XCTAssertEqual(joiner.tasks.count, ReplicaLimits.maxOrigins - 1)

        joiner.createPrivateSync()
        XCTAssertNil(joiner.invitationURL)
        XCTAssertEqual(joiner.errorMessage, SyncError.taskHistoryAtCapacity.errorDescription)
    }

    func testEraseRestartAndRelinkConvergesRetainedAndNewTasks() async throws {
        try await assertEraseRestartAndRelinkConverges(versionOneArchive: false)
    }

    func testEraseAfterUpgradeFromVersionOneArchiveConverges() async throws {
        try await assertEraseRestartAndRelinkConverges(versionOneArchive: true)
    }

    private func assertEraseRestartAndRelinkConverges(versionOneArchive: Bool) async throws {
        if versionOneArchive {
            let store = MemorySecretStore()
            stores["erase-peer"] = store
            let identity = try InstallIdentity.loadOrCreate(store: store)
            let directory = root.appendingPathComponent("erase-peer")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = try TaskReplica(
                deviceID: ReplicaDeviceID(bytes: identity.deviceID),
                persistenceURL: directory.appendingPathComponent("replica-v1.json")
            )
        }
        let host = engine("erase-host")
        let peer = engine("erase-peer")
        XCTAssertTrue(peer.addTask(title: "Before erase"))
        let originBeforeErase = peer.replicaForTesting.localOrigin
        if versionOneArchive {
            XCTAssertEqual(originBeforeErase.bytes, peer.localDeviceID)
        } else {
            XCTAssertNotEqual(originBeforeErase.bytes, peer.localDeviceID)
        }
        try await pair(host, peer)
        try await wait("initial copy") { host.tasks.map(\.titleValue) == ["Before erase"] && peer.phase == .synced }

        let stableID = peer.localDeviceID
        peer.eraseLocalData()
        XCTAssertEqual(peer.localDeviceID, stableID)
        XCTAssertTrue(peer.tasks.isEmpty)
        XCTAssertNotEqual(peer.replicaForTesting.localOrigin, originBeforeErase)
        try await wait("departure completes") { host.linkedMemberCount == 1 }
        await peer.stop()

        let restarted = engine("erase-peer")
        XCTAssertEqual(restarted.localDeviceID, stableID)
        XCTAssertEqual(restarted.replicaForTesting.localOrigin, peer.replicaForTesting.localOrigin)
        XCTAssertTrue(restarted.addTask(title: "After erase"))
        try await pair(host, restarted)
        let expected: Set<String> = ["Before erase", "After erase"]
        try await wait("relinked converges") {
            Set(host.tasks.compactMap(\.titleValue)) == expected
                && Set(restarted.tasks.compactMap(\.titleValue)) == expected
                && host.phase == .synced && restarted.phase == .synced
                && host.pendingMailboxOperationCount == 0 && restarted.pendingMailboxOperationCount == 0
        }
        XCTAssertEqual(host.tasks.map(\.id), restarted.tasks.map(\.id))

        XCTAssertTrue(host.addTask(title: "After relink"))
        try await wait("edits keep flowing") { restarted.tasks.count == 3 }
        XCTAssertNil(host.mailboxError)
        XCTAssertNil(restarted.mailboxError)
    }

    func testMissingArchiveWithSurvivingLinkUploadsFromItsNewOrigin() async throws {
        try await assertMissingArchiveUploadsFromNewOrigin(versionOneCheckpoint: false)
    }

    func testMissingArchiveWithVersionOneCheckpointUploadsFromItsNewOrigin() async throws {
        try await assertMissingArchiveUploadsFromNewOrigin(versionOneCheckpoint: true)
    }

    private func assertMissingArchiveUploadsFromNewOrigin(versionOneCheckpoint: Bool) async throws {
        let host = engine("archive-host")
        let peer = engine("archive-peer")
        XCTAssertTrue(peer.addTask(title: "First"))
        XCTAssertTrue(peer.addTask(title: "Second"))
        try await pair(host, peer)
        try await wait("uploaded") {
            host.tasks.count == 2 && peer.phase == .synced && peer.pendingMailboxOperationCount == 0
        }
        let previousOrigin = peer.replicaForTesting.localOrigin
        await peer.stop()

        let directory = root.appendingPathComponent("archive-peer")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("replica-v1.json"))
        let checkpointURL = directory.appendingPathComponent(ReplicationCheckpoint.filename)
        var checkpoint = try XCTUnwrap(ReplicationCheckpoint.load(from: checkpointURL))
        XCTAssertEqual(checkpoint.uploadedThrough, 2)
        XCTAssertEqual(checkpoint.uploadOrigin, previousOrigin)
        if versionOneCheckpoint {
            checkpoint.uploadOrigin = nil
            try checkpoint.save(to: checkpointURL)
        }

        let interrupted = engine("archive-peer")
        let newOrigin = interrupted.replicaForTesting.localOrigin
        XCTAssertNotEqual(newOrigin, previousOrigin)
        await interrupted.stop()

        let restarted = engine("archive-peer")
        XCTAssertTrue(restarted.isPaired)
        XCTAssertEqual(restarted.replicaForTesting.localOrigin, newOrigin)
        XCTAssertTrue(restarted.addTask(title: "After archive loss"))
        XCTAssertEqual(restarted.pendingMailboxOperationCount, 1)
        try await wait("new origin uploads") {
            host.tasks.contains { $0.titleValue == "After archive loss" }
                && restarted.pendingMailboxOperationCount == 0
        }
    }

    func testReusedOperationIDWithDifferentContentStopsSync() async throws {
        let store = MemorySecretStore()
        stores["legacy-peer"] = store
        let identity = try InstallIdentity.loadOrCreate(store: store)
        let installOrigin = try ReplicaDeviceID(bytes: identity.deviceID)
        let peerDirectory = root.appendingPathComponent("legacy-peer")
        let archiveURL = peerDirectory.appendingPathComponent("replica-v1.json")
        try FileManager.default.createDirectory(at: peerDirectory, withIntermediateDirectories: true)
        var before = try TaskReplica(deviceID: installOrigin, persistenceURL: archiveURL)
        try before.createTask(title: "Before erase")

        let host = engine("legacy-host")
        let peer = engine("legacy-peer")
        XCTAssertEqual(peer.replicaForTesting.localOrigin, installOrigin)
        try await pair(host, peer)
        try await wait("initial copy") { host.tasks.map(\.titleValue) == ["Before erase"] && peer.phase == .synced }
        peer.eraseLocalData()
        try await wait("departure completes") { host.linkedMemberCount == 1 }
        await peer.stop()

        try FileManager.default.removeItem(at: archiveURL)
        var reused = try TaskReplica(deviceID: installOrigin, persistenceURL: archiveURL)
        try reused.createTask(title: "After erase")
        try reused.createTask(title: "Second after erase")
        let relinked = engine("legacy-peer")
        XCTAssertEqual(relinked.replicaForTesting.localOrigin, installOrigin)
        let hostArchive = try host.replicaForTesting.atomicArchiveData()
        try await pair(host, relinked)

        try await wait("conflict surfaced") { host.mailboxError == .syncHistoryConflict }
        XCTAssertEqual(host.phase, .failed)
        XCTAssertTrue(host.mailboxRequiresRepair)
        XCTAssertEqual(host.errorMessage, SyncError.syncHistoryConflict.errorDescription)
        XCTAssertTrue(host.isPaired)
        XCTAssertEqual(host.tasks.map(\.titleValue), ["Before erase"])
        XCTAssertEqual(try host.replicaForTesting.atomicArchiveData(), hostArchive)
        let inbox = try await XCTUnwrapAsync(await host.mlsSessionForTesting?.inbox())
        XCTAssertFalse(inbox.isEmpty)
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
            keyPackageReference: published.reference, joinerFingerprint: published.fingerprint, joinerNonce: nonce, origins: []
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
                    keyPackageReference: ground.reference, joinerFingerprint: ground.fingerprint, joinerNonce: nonce, origins: []
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

    func testExpiredRelayHistoryStopsSyncAndIsSurfaced() async throws {
        let host = engine("host")
        let joiner = engine("joiner")
        try await pair(host, joiner)
        try await wait("synced") { joiner.phase == .synced }
        await relay.expireHistory(group: try await groupID(host))
        XCTAssertTrue(host.addTask(title: "After expiry"))
        try await wait("expired") { joiner.phase == .failed }
        XCTAssertEqual(joiner.mailboxError, .syncHistoryExpired)
        XCTAssertTrue(joiner.mailboxRequiresRepair)
        XCTAssertEqual(joiner.errorMessage, SyncError.syncHistoryExpired.errorDescription)
        XCTAssertTrue(joiner.isPaired)
        XCTAssertEqual(SyncError.fromTransport(MLSRelayError.historyExpired) as? SyncError, .syncHistoryExpired)
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
        for account in LegacyLinkCredentials.accounts {
            try store.write(Data("version 1".utf8), account: account)
        }

        let upgraded = engine("legacy")
        XCTAssertFalse(upgraded.isPaired)
        XCTAssertEqual(upgraded.phase, .unpaired)
        XCTAssertEqual(upgraded.tasks.map(\.titleValue), ["From version 1"])
        XCTAssertEqual(upgraded.errorMessage, SyncError.relinkRequired.errorDescription)
        XCTAssertEqual(upgraded.linkEndedReason, .relinkRequired)
        for account in LegacyLinkCredentials.accounts {
            XCTAssertNil(try store.read(account: account), account)
        }
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
            try await wait("membership") {
                current.allSatisfy { $0.linkedMemberCount == expected && !$0.awaitsReservationsForTesting }
            }
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
        for attempt in 1...5 {
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                break
            } catch CocoaError.fileNoSuchFile where attempt < 5 {
                try? FileManager.default.removeItem(at: destination)
            }
        }
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
            XCTAssertEqual(removedDevice.linkEndedReason, .removedFromGroup)
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

    func testLeaveFromExpiredGroupIsNotRetried() async throws {
        let host = engine("expired-host")
        let leaver = engine("expired-leaver", departureRetryDelayNanoseconds: 1_000_000...20_000_000)
        try await pair(host, leaver)
        await relay.expireHistory(group: try await groupID(host))
        leaver.unlinkAndKeepTasks()
        let departures = root.appendingPathComponent("expired-leaver").appendingPathComponent(SyncEngine.departuresDirectoryName)
        try await wait("departure erased") {
            ((try? FileManager.default.contentsOfDirectory(atPath: departures.path)) ?? []).isEmpty
        }
        XCTAssertFalse(leaver.isPaired)
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

    /// The member is offline while the host writes. One copy of its state
    /// shows those messages were readable; another skips them, processes only
    /// the commit, and must then fail to open them.
    func testStateAfterEpochChangeCannotDecryptEarlierEpochs() async throws {
        let names = ["epoch-0", "epoch-1"]
        let linked = try await linkedGroup(names)
        let host = linked[0]
        let group = try await groupID(host)
        await linked[1].stop()
        let title = "Written before the epoch change"
        XCTAssertTrue(host.addTask(title: title))
        try await wait("uploaded") { host.pendingMailboxOperationCount == 0 }

        let control = try await retainedState(of: names[1], engine: linked[1], copy: "epoch-control")
        let skipping = try await retainedState(of: names[1], engine: linked[1], copy: "epoch-skipping")
        let earlierEpoch = try await control.epoch()
        let controlCursor = try await control.cursor()
        let unread = await relay.log(group: group).filter { $0.delivery.kind == .application && $0.cursor > controlCursor }
        XCTAssertFalse(unread.isEmpty)
        for entry in unread {
            try await control.process(entry.delivery, cursor: entry.cursor)
        }
        let opened = Set(try await control.inbox().map(\.cursor))
        XCTAssertTrue(Set(unread.map(\.cursor)).isSubset(of: opened))

        try await pair(host, engine("epoch-2"))
        let member = engine(names[1])
        try await wait("epoch change received") {
            member.linkedMemberCount == 3 && member.tasks.contains { $0.titleValue == title }
        }
        let commits = await relay.log(group: group).filter { $0.delivery.kind == .commit && $0.cursor > controlCursor }
        XCTAssertFalse(commits.isEmpty)
        for entry in commits {
            try await skipping.process(entry.delivery, cursor: entry.cursor)
        }
        let skippedEpoch = try await skipping.epoch()
        XCTAssertGreaterThan(skippedEpoch, earlierEpoch)
        var skippedCursor = try await skipping.cursor()
        var skipped: [UInt64] = []
        for entry in unread {
            skippedCursor += 1
            skipped.append(skippedCursor)
            try await skipping.process(entry.delivery, cursor: skippedCursor)
        }
        let skippedInbox = Set(try await skipping.inbox().map(\.cursor))
        XCTAssertTrue(skippedInbox.isDisjoint(with: skipped), "state retained an earlier epoch's keys")

        let snapshot = try await retainedState(of: names[1], engine: member, copy: "epoch-snapshot")
        let currentEpoch = try await snapshot.epoch()
        XCTAssertGreaterThan(currentEpoch, earlierEpoch)
        let earlier = await relay.log(group: group).filter { $0.delivery.kind == .application && $0.delivery.epoch < currentEpoch }
        XCTAssertTrue(Set(unread.map(\.cursor)).isSubset(of: Set(earlier.map(\.cursor))))

        var cursor = try await snapshot.cursor()
        var replayed: [UInt64] = []
        for entry in earlier {
            cursor += 1
            replayed.append(cursor)
            try await snapshot.process(entry.delivery, cursor: cursor)
        }
        let inbox = Set(try await snapshot.inbox().map(\.cursor))
        XCTAssertTrue(inbox.isDisjoint(with: replayed), "a post-change snapshot decrypted an earlier epoch")
        let rejected = Set(try await snapshot.rejectedApplicationCursors())
        XCTAssertTrue(Set(replayed).isSubset(of: rejected))
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
                    keyPackageReference: published.reference, joinerFingerprint: published.fingerprint, joinerNonce: nonce, origins: []
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
