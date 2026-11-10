import Foundation
import GotSyncMLS
import os
import XCTest
@_spi(HostJournalPreview) @testable import GotSync

/// A secret store that can hold the MLS state key's read or write until
/// released, so a test can act while a launch's session constructor runs.
final class GatedSecretStore: SecretStore {
    enum Point: Sendable { case read, write }

    private struct State {
        var held: Point?
        var failsAfterRelease = false
        var failsDeletes = false
        var waiting = false
        var reads = 0
        var writes = 0
    }

    private let base: MemorySecretStore
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let release = DispatchSemaphore(value: 0)

    init(_ base: MemorySecretStore, holding point: Point?) {
        self.base = base
        state.withLock { $0.held = point }
    }

    var isWaiting: Bool { state.withLock { $0.waiting } }
    var keyReads: Int { state.withLock { $0.reads } }
    var keyWrites: Int { state.withLock { $0.writes } }

    /// Makes every later delete of the MLS state key fail.
    func failDeletes() {
        state.withLock { $0.failsDeletes = true }
    }

    /// Releases a held call; with `failing`, that call then throws.
    func open(failing: Bool = false) {
        let wasWaiting = state.withLock { state in
            state.held = nil
            state.failsAfterRelease = failing
            return state.waiting
        }
        if wasWaiting { release.signal() }
    }

    private func pass(_ point: Point, _ account: String) throws {
        guard account == SecretStoreMLSStateKey.account else { return }
        let hold = state.withLock { state -> Bool in
            if point == .read { state.reads += 1 } else { state.writes += 1 }
            guard state.held == point else { return false }
            state.waiting = true
            return true
        }
        guard hold else { return }
        release.wait()
        let fails = state.withLock { state in
            state.waiting = false
            defer { state.failsAfterRelease = false }
            return state.failsAfterRelease
        }
        if fails { throw CocoaError(.fileReadUnknown) }
    }

    func read(account: String) throws -> Data? {
        try pass(.read, account)
        return try base.read(account: account)
    }

    func write(_ data: Data, account: String) throws {
        try pass(.write, account)
        try base.write(data, account: account)
    }

    func write(_ data: Data, account: String, accessibility: SecretAccessibility) throws {
        try pass(.write, account)
        try base.write(data, account: account, accessibility: accessibility)
    }

    func delete(account: String) throws {
        if account == SecretStoreMLSStateKey.account, state.withLock({ $0.failsDeletes }) {
            throw CocoaError(.fileWriteUnknown)
        }
        try base.delete(account: account)
    }
}

/// Launch ownership: one settlement of the session constructor and the
/// journal observation, shared by launch, stop and closing.
extension HostEngineTests {
    func testAURLJoinRequestedDuringOpeningStartsAfterTheLaunchSettles() async throws {
        try await joinWhileOpening(usePhrase: false)
    }

    func testAPhraseJoinRequestedDuringOpeningStartsAfterTheLaunchSettles() async throws {
        try await joinWhileOpening(usePhrase: true)
    }

    private func joinWhileOpening(usePhrase: Bool) async throws {
        let first = engine("first")
        first.createPrivateSync()
        try await wait("invitation") { first.invitationURL != nil }
        let (second, gate) = gatedEngine("second", holding: .read)
        defer { gate.open() }
        try await eventually { gate.isWaiting }
        XCTAssertEqual(second.hostLifecycle, .opening)
        XCTAssertNil(second.mlsSessionForTesting)
        if usePhrase {
            second.joinPrivateSync(phrase: try XCTUnwrap(first.invitationPhrase))
        } else {
            second.joinPrivateSync(url: try XCTUnwrap(first.invitationURL))
        }
        gate.open()
        try await wait("join requested during opening reaches verification") {
            first.isHostApprovalPending && second.safetyCode != nil
        }
        XCTAssertEqual(first.safetyCode, second.safetyCode)
        XCTAssertEqual(second.hostLaunchesForTesting, 1)
        first.approveSafetyCode()
        try await wait("paired") { first.isPaired && second.isPaired && !first.canCancelPairing }
    }

    func gatedEngine(_ name: String, holding point: GatedSecretStore.Point?) -> (SyncEngine, GatedSecretStore) {
        let base = stores[name] ?? MemorySecretStore()
        stores[name] = base
        let gated = GatedSecretStore(base, holding: point)
        let engine = SyncEngine(
            configuration: try! SyncConfiguration(
                relayURL: TestEndpoints.relayURL,
                mailboxURL: TestEndpoints.mailboxURL,
                storageDirectory: directory(name),
                invitationURLScheme: "gotsync-tests",
                endpointPolicy: .localDevelopment,
                groupProfile: profile
            ),
            secretStore: gated,
            backgroundMailboxScheduler: nil,
            pairingRetryDelayNanoseconds: 20_000_000,
            mlsTransport: relay,
            rendezvous: rendezvous,
            syncIntervalNanoseconds: 50_000_000
        )
        engines.append(engine)
        return (engine, gated)
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Every file under the MLS root with its size and modification date.
    private func mlsFiles(_ name: String) throws -> [String: String] {
        let root = MLSSession.directory(in: directory(name))
        var result: [String: String] = [:]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return result
        }
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            result[url.path] = "\(values.fileSize ?? -1) \(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        return result
    }

    func testStopWaitsForAFreshIdentityAndARelaunchKeepsIt() async throws {
        let (launching, gate) = gatedEngine("b", holding: .write)
        try await eventually { gate.isWaiting }
        var stopped = false
        let stopping = Task(priority: .high) {
            await launching.stop()
            stopped = true
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(stopped, "stop returned while the session constructor was writing")
        gate.open()
        await stopping.value
        let fingerprint = try await XCTUnwrapAsync(launching.mlsSessionForTesting).fingerprint()
        let files = try mlsFiles("b")
        let key = try stores["b"]?.read(account: SecretStoreMLSStateKey.account)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try mlsFiles("b"), files, "a write followed stop")
        XCTAssertEqual(try stores["b"]?.read(account: SecretStoreMLSStateKey.account), key)
        engines.removeAll { $0 === launching }
        let relaunched = engine("b")
        await opened(relaunched)
        let relaunchedFingerprint = try await XCTUnwrapAsync(relaunched.mlsSessionForTesting).fingerprint()
        XCTAssertEqual(relaunchedFingerprint, fingerprint)
    }

    func testStopWaitsForAResealOfALinkedSessionAndItsLogicalStateSurvives() async throws {
        let (_, b) = try await completedPair()
        let session = try XCTUnwrap(b.mlsSessionForTesting)
        let before = (try await session.group(), try await session.epoch(), try await session.cursor(), try await session.inbox())
        await b.stop()
        engines.removeAll { $0 === b }
        let (relaunched, gate) = gatedEngine("b", holding: .read)
        try await eventually { gate.isWaiting }
        var stopped = false
        let stopping = Task(priority: .high) {
            await relaunched.stop()
            stopped = true
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(stopped, "stop returned while the session constructor resealed the record")
        gate.open()
        await stopping.value
        let files = try mlsFiles("b")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try mlsFiles("b"), files, "a write followed stop")
        let reopened = try XCTUnwrap(relaunched.mlsSessionForTesting)
        let after = (try await reopened.group(), try await reopened.epoch(), try await reopened.cursor(), try await reopened.inbox())
        XCTAssertEqual(after.0, before.0)
        XCTAssertEqual(after.1, before.1)
        XCTAssertEqual(after.2, before.2)
        XCTAssertEqual(after.3, before.3)
    }

    func testUnlinkDuringOpeningHandsTheHeldInboxToTheJournal() async throws {
        let (a, b) = try await completedPair()
        let journalID = try store(b).view.journalID
        await b.stop()
        engines.removeAll { $0 === b }
        try await submit(a, "a", ["held one", "held two"])
        try await wait("uploaded") { a.hostView?.unuploaded == 0 }
        let bSession = try XCTUnwrap(b.mlsSessionForTesting)
        _ = try await bSession.synchronize()
        let held = try await bSession.inbox()
        XCTAssertFalse(held.isEmpty)
        let relaunched = engine("b")
        var gate: CheckedContinuation<Void, Never>?
        relaunched.preparedJournalHookForTesting = { _ in
            relaunched.preparedJournalHookForTesting = nil
            await withCheckedContinuation { gate = $0 }
        }
        try await wait("journal open held") { gate != nil }
        XCTAssertNotNil(relaunched.mlsSessionForTesting, "the settled session was not installed before journal opening")
        relaunched.unlinkAndKeepTasks()
        gate?.resume()
        try await wait("unlinked") { relaunched.hostLifecycle == .active && !relaunched.isPaired }
        let url = HostJournalStore.fileURL(in: directory("b"), journalID: journalID)
        XCTAssertEqual(try HostJournalStore.open(url).view.retirement, .unlink)
        let exported = try JournalFixture.exportAll(url).compactMap { item -> Data? in
            if case .held(_, _, let plaintext) = item { return plaintext }
            return nil
        }
        XCTAssertEqual(exported, held.map(\.plaintext), "held inbox bytes were not handed to the journal")
    }

    func testUnlinkWhileTheSessionIsStillBuildingHandsTheHeldInboxToTheJournal() async throws {
        let (a, b) = try await completedPair()
        let journalID = try store(b).view.journalID
        await b.stop()
        engines.removeAll { $0 === b }
        try await submit(a, "a", ["held while building"])
        try await wait("uploaded") { a.hostView?.unuploaded == 0 }
        let bSession = try XCTUnwrap(b.mlsSessionForTesting)
        _ = try await bSession.synchronize()
        let held = try await bSession.inbox()
        XCTAssertFalse(held.isEmpty)
        let (relaunched, gate) = gatedEngine("b", holding: .read)
        try await eventually { gate.isWaiting }
        XCTAssertNil(relaunched.mlsSessionForTesting)
        relaunched.unlinkAndKeepTasks()
        XCTAssertEqual(relaunched.hostLifecycle, .closing(.unlink))
        gate.open()
        try await wait("unlinked") { relaunched.hostLifecycle == .active && !relaunched.isPaired }
        let url = HostJournalStore.fileURL(in: directory("b"), journalID: journalID)
        XCTAssertEqual(try HostJournalStore.open(url).view.retirement, .unlink)
        let exported = try JournalFixture.exportAll(url).compactMap { item -> Data? in
            if case .held(_, _, let plaintext) = item { return plaintext }
            return nil
        }
        XCTAssertEqual(exported, held.map(\.plaintext), "closing did not receive the session that was still building")
    }

    func testRemovalOfAJoinerWithOnlyAJoinIntentHandsTheInboxToTheIntentJournal() async throws {
        let (a, b) = try await completedPair()
        let journalID = try store(b).view.journalID
        let bFingerprint = try await fingerprint(b)
        let bSession = try XCTUnwrap(b.mlsSessionForTesting)
        await b.stop()
        engines.removeAll { $0 === b }
        let checkpointURL = directory("b").appendingPathComponent(ReplicationCheckpoint.filename)
        var intent = try XCTUnwrap(ReplicationCheckpoint.load(from: checkpointURL))
        intent.members = []
        try intent.save(to: directory("b").appendingPathComponent(ReplicationCheckpoint.joinIntentFilename))
        try FileManager.default.removeItem(at: checkpointURL)
        try await submit(a, "a", ["held before removal"])
        try await wait("uploaded") { a.hostView?.unuploaded == 0 }
        XCTAssertTrue(a.removeDevice(fingerprint: bFingerprint))
        try await wait("removed") { a.linkedMemberCount == 1 }
        _ = try await bSession.synchronize()
        let removedBeforeLaunch = try await bSession.isRemoved()
        XCTAssertTrue(removedBeforeLaunch, "the removal must be known before the relaunch rebuilds a checkpoint")
        let relaunched = engine("b")
        try await wait("closed after removal", timeout: .seconds(10)) {
            relaunched.hostLifecycle == .active && !relaunched.isPaired && relaunched.hostView?.journal == nil
        }
        let url = HostJournalStore.fileURL(in: directory("b"), journalID: journalID)
        XCTAssertEqual(try HostJournalStore.open(url).view.retirement, .removed, "the intent's journal did not take the inbox")
        let exported = try JournalFixture.exportAll(url).compactMap { item -> Data? in
            if case .held(_, _, let plaintext) = item { return plaintext }
            return nil
        }
        XCTAssertFalse(exported.isEmpty, "no held bytes reached the intent's journal")
    }

    func testEraseDuringOpeningWaitsForTheConstructorAndNothingReappears() async throws {
        let (launching, gate) = gatedEngine("b", holding: .write)
        try await eventually { gate.isWaiting }
        let old = launching.mlsDirectoryForTesting
        launching.eraseLocalData()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(gate.isWaiting, "erase did not wait for the constructor")
        XCTAssertEqual(launching.hostLifecycle, .closing(.erase))
        XCTAssertEqual(gate.keyReads, 1, "a second constructor started while the first was held")
        gate.open()
        try await wait("erased") { launching.hostLifecycle == .active && launching.mlsSessionForTesting != nil }
        XCTAssertNotEqual(launching.mlsDirectoryForTesting, old)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "a stale write recreated erased state")
    }

    func testErasedSessionIsClosedBeforeItsFilesAreRemoved() async throws {
        let (_, b) = try await completedPair()
        let old = try XCTUnwrap(b.mlsSessionForTesting)
        b.eraseLocalData()
        try await wait("erased") { b.hostLifecycle == .active && !b.isPaired }
        await XCTAssertThrowsErrorAsync(try await old.fingerprint()) {
            XCTAssertEqual($0 as? MLSClientError, .storageUnavailable, "the erased session's store stayed open")
        }
    }

    func testStopDuringOpeningThenRepeatedActivationStartsOneNewLaunch() async throws {
        let (_, b) = try await completedPair()
        await b.stop()
        engines.removeAll { $0 === b }
        let relaunched = engine("b")
        var gate: CheckedContinuation<Void, Never>?
        relaunched.preparedJournalHookForTesting = { _ in await withCheckedContinuation { gate = $0 } }
        try await wait("journal open held") { gate != nil }
        let stopping = Task { await relaunched.stop() }
        try await Task.sleep(for: .milliseconds(50))
        gate?.resume()
        await stopping.value
        relaunched.preparedJournalHookForTesting = nil
        XCTAssertEqual(relaunched.hostLifecycle, .opening)
        XCTAssertEqual(relaunched.hostLaunchesForTesting, 1)
        relaunched.applicationDidBecomeActive()
        relaunched.applicationDidBecomeActive()
        await opened(relaunched)
        XCTAssertEqual(relaunched.hostLifecycle, .active)
        XCTAssertEqual(relaunched.hostLaunchesForTesting, 2, "repeated activation started more than one launch")
        XCTAssertNotNil(relaunched.hostJournal)
        XCTAssertNil(relaunched.hostRepair)
    }

    func testLaunchInputsThatKeepChangingEndInARepairWithFilesKept() async throws {
        let (_, b) = try await completedPair()
        await b.stop()
        engines.removeAll { $0 === b }
        let files = try Self.journalFiles(directory("b"))
        let relaunched = engine("b")
        var observed = 0
        relaunched.launchObservationHookForTesting = {
            observed += 1
            var intent = ReplicationCheckpoint(group: Data(repeating: UInt8(observed), count: 32), members: [], joinPending: true, provider: nil)
            intent.hostJournal = Data(repeating: UInt8(observed), count: 16)
            try? intent.save(to: self.directory("b").appendingPathComponent(ReplicationCheckpoint.joinIntentFilename))
        }
        await opened(relaunched)
        XCTAssertEqual(observed, 3, "the observation was not bounded to three attempts")
        guard case .launchInputsChanged? = relaunched.hostRepair else { return XCTFail("no terminal launch failure") }
        XCTAssertEqual(relaunched.phase, .failed)
        XCTAssertEqual(try Self.journalFiles(directory("b")), files)
    }

    func testClosingDropsAHeldObservationWithoutRetrying() async throws {
        let (_, b) = try await completedPair()
        await b.stop()
        engines.removeAll { $0 === b }
        let relaunched = engine("b")
        var observed = 0
        var gate: CheckedContinuation<Void, Never>?
        relaunched.launchObservationHookForTesting = {
            observed += 1
            await withCheckedContinuation { gate = $0 }
        }
        try await wait("observation held") { gate != nil }
        relaunched.unlinkAndKeepTasks()
        gate?.resume()
        try await wait("unlinked") { relaunched.hostLifecycle == .active && !relaunched.isPaired }
        XCTAssertEqual(observed, 1, "closing started another observation")
    }

    func testAnOrphanEnrolledWhileTheObservationWasHeldIsRetiredNotDeleted() async throws {
        let (_, b) = try await completedPair()
        await b.stop()
        engines.removeAll { $0 === b }
        let orphanURL = try HostJournalStore.create(in: directory("b"), group: JournalFixture.group).url
        let relaunched = engine("b")
        var gate: CheckedContinuation<Void, Never>?
        relaunched.launchObservationHookForTesting = { await withCheckedContinuation { gate = $0 } }
        try await wait("observation held") { gate != nil }
        do {
            let orphan = try HostJournalStore.open(orphanURL)
            _ = try orphan.enroll()
        }
        gate?.resume()
        await opened(relaunched)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanURL.path), "an orphan enrolled after the observation was deleted")
        XCTAssertEqual(try HostJournalStore.open(orphanURL).view.retirement, .orphaned)
    }

    func testAFailureOfAStoppedLaunchIsNotPublishedAndReactivationOpens() async throws {
        let (_, b) = try await completedPair()
        await b.stop()
        engines.removeAll { $0 === b }
        let (relaunched, gate) = gatedEngine("b", holding: .read)
        try await eventually { gate.isWaiting }
        let stopping = Task { await relaunched.stop() }
        try await Task.sleep(for: .milliseconds(100))
        gate.open(failing: true)
        await stopping.value
        XCTAssertNil(relaunched.hostRepair, "a stopped launch published its failure")
        XCTAssertNil(relaunched.mlsSessionForTesting)
        relaunched.applicationDidBecomeActive()
        await opened(relaunched)
        XCTAssertEqual(relaunched.hostLifecycle, .active)
        XCTAssertNil(relaunched.hostRepair)
        XCTAssertNotNil(relaunched.mlsSessionForTesting)
        XCTAssertNotNil(relaunched.hostJournal)
    }

    func testNothingKeepsAReplacedSessionAliveAfterErase() async throws {
        let (_, b) = try await completedPair()
        let replaced = WeakSessionReference(b.mlsSessionForTesting)
        XCTAssertNotNil(replaced.value)
        b.eraseLocalData()
        try await wait("erased") { b.hostLifecycle == .active && !b.isPaired }
        try await wait("released") { replaced.value == nil }
    }

    func testStopAndClosingJoinOneSettlement() async throws {
        let (_, b) = try await completedPair()
        await b.stop()
        engines.removeAll { $0 === b }
        let (relaunched, gate) = gatedEngine("b", holding: .read)
        try await eventually { gate.isWaiting }
        relaunched.eraseLocalData()
        let stopping = Task { await relaunched.stop() }
        try await Task.sleep(for: .milliseconds(100))
        gate.open()
        await stopping.value
        XCTAssertEqual(gate.keyReads, 1, "a second constructor ran while the first was settling")
        XCTAssertNotNil(relaunched.mlsSessionForTesting)
    }
}

@MainActor
private final class WeakSessionReference {
    weak var value: MLSSession?

    init(_ value: MLSSession?) { self.value = value }
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
